#!/usr/bin/env bash
# Debian 10-13; Ubuntu 18.04/20.04/22.04/24.04/26.04 LTS and 25.10.
# Usage: bash install-general-key.sh [existing-user] [public-key-file]
# Only old-key deletion requires confirmation. Success disables SSH passwords globally.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077
die() { printf '终止：%s\n' "$*" >&2; exit 1; }
[[ $# -le 2 ]] || die '用法：bash install-general-key.sh [用户名] [公钥文件]'
[[ -r /etc/os-release ]] || die '找不到 /etc/os-release'
. /etc/os-release
case "${ID:-}:${VERSION_ID:-}" in
  debian:10|debian:11|debian:12|debian:13|ubuntu:18.04|ubuntu:20.04|ubuntu:22.04|ubuntu:24.04|ubuntu:26.04|ubuntu:25.10) ;;
  *) die "未支持的系统：${PRETTY_NAME:-unknown}；未修改配置" ;;
esac
target=${1:-${SUDO_USER:-$(id -un)}}
if [[ $EUID != 0 ]]; then
  command -v sudo >/dev/null || die '当前不是 root 且没有 sudo，无法自行安装 sudo。请先 su - 切换 root，再执行脚本并指定原用户名。'
  script=$(readlink -f -- "${BASH_SOURCE[0]}")
  [[ -f $script ]] || die '请先下载脚本到文件再运行'
  args=("$target")
  if [[ $# == 2 ]]; then args+=("$(readlink -f -- "$2")"); fi
  exec sudo -- /bin/bash "$script" "${args[@]}"
fi
[[ -d /run/systemd/system ]] || die '不是使用 systemd 的完整服务器系统，未修改 SSH'
for tool in apt-get getent flock ssh-keygen systemctl stat; do
  command -v "$tool" >/dev/null || die "缺少必要命令 $tool；请先修复系统"
done
# Install missing tools only. Never rewrite old distribution mirrors or upgrade SSH.
packages=()
command -v sudo >/dev/null || packages+=(sudo)
command -v python3 >/dev/null || packages+=(python3)
if [[ ${#packages[@]} -gt 0 ]]; then
  printf '以 root 安装缺失依赖：%s\n' "${packages[*]}"
  apt-get update || die '软件源更新失败（可能是旧版本源、网络或 APT 锁问题）；未修改 SSH 配置'
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}" \
    || die '依赖安装失败；未修改 SSH 配置'
fi
sshd=/usr/sbin/sshd
config=/etc/ssh/sshd_config
[[ -x $sshd && -f $config && ! -L $config ]] || die '不支持此 SSH 安装路径或符号链接配置'
exec 8< /etc/ssh
flock -n -x 8 || die '另一实例正在操作 SSH；请稍后再试'
# Do not let a rollback timer from an older installer undo this run later.
if systemctl list-units --all --plain --no-legend 'ssh-key-rollback-*.timer' | grep -q 'ssh-key-rollback-'; then
  die '发现旧版脚本的恢复定时器；请先完成旧版确认或等待其恢复后再执行'
fi
unit=
for candidate in ssh.service sshd.service; do
  if systemctl is-active --quiet "$candidate"; then unit=$candidate; break; fi
done
[[ -n $unit ]] || die '未找到运行中的 SSH 服务；不会自动启动/重启服务'
[[ $(systemctl show "$unit" -p CanReload --value) == yes ]] || die '服务不支持 reload；请人工检查'
pid=$(systemctl show "$unit" -p MainPID --value)
python3 - "$pid" <<'PY_PROCESS' || die 'SSH 主进程使用自定义配置/参数或无法检查，未修改 SSH'
import pathlib, re, sys
text = pathlib.Path('/proc/' + sys.argv[1] + '/cmdline').read_bytes().replace(b'\0', b' ').decode()
if re.search(r'(^|\s)-[^\s]*[fo]', text):
    raise SystemExit('拒绝 -f/-o 自定义启动参数: ' + text)
PY_PROCESS
entry=$(getent passwd "$target") || die "用户不存在：$target"
IFS=: read -r account unused uid gid gecos home login_shell <<< "$entry"
[[ $account == "$target" && $home == /* && -d $home ]] || die '目标用户/home 无效'
[[ -x $login_shell && $login_shell != */nologin && $login_shell != */false ]] || die '用户没有可登录的 shell'
[[ ! -e /etc/nologin && ! -e /run/nologin ]] || die '系统存在 nologin 标记，停止以避免锁死'
printf '系统：%s；目标用户：%s；公钥文件：%s/.ssh/authorized_keys\n' "$PRETTY_NAME" "$target" "$home"
printf '成功后将全局关闭 SSH 密码认证；不会改动其他用户的公钥。\n'
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
if [[ $# == 2 ]]; then
  [[ -f $2 && -r $2 ]] || die '公钥文件不存在或不可读'
  cp -- "$2" "$tmp/input"
else
  printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOY/BZiIF8fG9MDUF/gvE6+P2wYjAqQIVnyBTEoqG2Pz' > "$tmp/input"
fi
"$sshd" -t || die '原 SSH 配置校验失败；未修改'
"$sshd" -T > "$tmp/effective" || die '无法读取有效配置'
cat > "$tmp/helper.py" <<'PY_HELPER'
import glob, hashlib, json, os, pathlib, re, shlex, shutil, stat, subprocess, sys, time

def fail(message):
    raise ValueError(message)

def safe(path, directory=False, owners=(0,)):
    path = pathlib.Path(path)
    for parent in [path] + list(path.parents):
        if parent.is_symlink(): fail('符号链接路径: ' + str(parent))
    if path.exists():
        st = path.stat()
        if directory:
            if not stat.S_ISDIR(st.st_mode): fail('不是目录: ' + str(path))
        elif not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
            fail('不是普通单链接文件: ' + str(path))
        if st.st_uid not in owners or st.st_mode & 0o022:
            fail('所有者或组/其他用户写权限不安全: ' + str(path))

def digest(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()

def effective(path):
    return dict(line.split(None, 1) for line in pathlib.Path(path).read_text().splitlines() if ' ' in line)

def verify_policy(path):
    e = effective(path)
    for k, v in [('pubkeyauthentication','yes'), ('passwordauthentication','no'), ('authenticationmethods','publickey')]:
        if e.get(k) != v: fail('有效配置不符合预期: ' + k)
    interactive = [k for k in ('kbdinteractiveauthentication','challengeresponseauthentication') if k in e]
    if not interactive or any(e[k] != 'no' for k in interactive): fail('交互式密码认证未关闭')

def public_key(line, checkfile):
    words = line.split()
    plain_types = ('ssh-ed25519','ssh-rsa','ssh-dss','ecdsa-sha2-nistp256','ecdsa-sha2-nistp384','ecdsa-sha2-nistp521','sk-ssh-ed25519@openssh.com','sk-ecdsa-sha2-nistp256@openssh.com')
    if len(words) < 2 or words[0] not in plain_types:
        fail('公钥文件含限制选项、证书、私钥或无法识别的内容；不自动删除/放宽限制')
    checkfile.write_text(words[0] + ' ' + words[1] + '\n')
    result = subprocess.run(['ssh-keygen','-lf',str(checkfile),'-E','sha256'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
    if result.returncode: fail('无效的公钥内容')
    return words[:2], result.stdout.strip()

def audit(work, target, home, uid, gid, config):
    w = pathlib.Path(work); home = pathlib.Path(home); config = pathlib.Path(config)
    safe(home, True, (0,uid))
    # Check home ancestry as sshd StrictModes does for common home layouts.
    for parent in home.parents: safe(parent, True, (0,uid))
    sshdir = home / '.ssh'; auth = sshdir / 'authorized_keys'; alternate = sshdir / 'authorized_keys2'
    safe(sshdir, True, (0,uid)); safe(auth, owners=(0,uid)); safe(alternate, owners=(0,uid))
    if alternate.exists() and any(x.strip() and not x.lstrip().startswith('#') for x in alternate.read_text().splitlines()):
        fail('存在非空 authorized_keys2；需要人工处理额外密钥来源')
    seen = {}; stack = set()
    def scan(path):
        path = pathlib.Path(path)
        safe(path)
        if str(path) in stack: fail('SSH Include 循环: ' + str(path))
        if str(path) in seen: return
        stack.add(str(path)); seen[str(path)] = digest(path)
        for number, line in enumerate(path.read_text().splitlines(), 1):
            # OpenSSH accepts Keyword=value as well as Keyword value.
            line = re.sub(r'^([ \t]*[A-Za-z]+)[ \t]*=[ \t]*', r'\1 ', line)
            words = shlex.split(line, comments=True)
            if not words: continue
            key = words[0].lower()
            where = '{}:{}'.format(path, number)
            if key == 'match': fail('存在 Match 条件规则: ' + where)
            if key == 'authenticationmethods' and words[1:] not in (['any'],['publickey']): fail('存在多因素认证要求: ' + where)
            if key in ('allowusers','denyusers','allowgroups','denygroups'): fail('存在用户/组访问限制: ' + where)
            if key == 'include':
                for pattern in words[1:]:
                    if not pattern.startswith('/'): pattern = '/etc/ssh/' + pattern
                    for child in sorted(glob.glob(pattern)): scan(child)
        stack.remove(str(path))
    scan(config)
    e = effective(w/'effective')
    for k in ('authorizedkeyscommand','trustedusercakeys','authorizedprincipalscommand','authorizedprincipalsfile','revokedkeys','forcecommand','chrootdirectory'):
        if e.get(k, 'none') != 'none': fail('特殊 SSH 配置需要人工处理: ' + k)
    if e.get('authorizedkeysfile','').split() not in [['.ssh/authorized_keys'],['.ssh/authorized_keys','.ssh/authorized_keys2']]:
        fail('非标准 AuthorizedKeysFile，停止以避免遗漏密钥')
    if uid == 0 and e.get('permitrootlogin') not in ('yes','prohibit-password','without-password'):
        fail('当前配置不允许普通 root 公钥登录；不自动放宽 root 权限')
    alg = e.get('pubkeyacceptedalgorithms', e.get('pubkeyacceptedkeytypes',''))
    if alg and 'ssh-ed25519' not in alg.split(','): fail('服务器未允许 Ed25519 公钥算法')
    shadow = subprocess.check_output(['getent','shadow',target], universal_newlines=True).strip().split(':')
    today = int(time.time()//86400)
    if len(shadow) < 8: fail('无法读取账户有效期')
    if shadow[7] and int(shadow[7]) >= 0 and int(shadow[7]) <= today: fail('目标账户已过期')
    if shadow[2] == '0': fail('目标账户要求下次登录修改密码')
    if shadow[2] and shadow[4] and int(shadow[4]) >= 0 and int(shadow[2])+int(shadow[4]) <= today:
        fail('目标账户密码已过期，PAM 可能阻止登录')
    if e.get('usepam') != 'yes' and shadow[1].startswith(('!','*')): fail('账户已锁定且 UsePAM 不是 yes')
    lines = [x.strip() for x in (w/'input').read_text().splitlines() if x.strip()]
    if len(lines) != 1: fail('必须提供一把公钥')
    current, fingerprint = public_key(lines[0], w/'check.pub')
    if current[0] != 'ssh-ed25519': fail('新公钥必须为 Ed25519')
    canonical = ' '.join(current) + ' vps-general\n'
    old = auth.read_text() if auth.exists() else ''
    others = []; found = False
    for line in old.splitlines():
        if not line.strip() or line.lstrip().startswith('#'): continue
        identity, fp = public_key(line, w/'check.pub')
        if identity == current: found = True
        else: others.append(fp)
    keep = old
    if not found: keep = old + ('\n' if old and not old.endswith('\n') else '') + canonical
    (w/'keys.keep').write_text(keep)
    (w/'keys.replace').write_text(canonical)
    (w/'old-count').write_text(str(len(others)))
    print('当前公钥: ' + fingerprint)
    if others:
        print('检测到目标用户的其他旧公钥（{} 条）:'.format(len(others)))
        for fp in others: print('  ' + fp)
    # Pick names supported by this installed OpenSSH, including old Debian.
    interactive = [k for k in ('kbdinteractiveauthentication','challengeresponseauthentication') if k in e]
    if not interactive: fail('无法识别交互式认证配置名称')
    policy = '# Managed key-only SSH policy\nPubkeyAuthentication yes\nAuthenticationMethods publickey\nPasswordAuthentication no\n'
    policy += ''.join(k + ' no\n' for k in interactive)
    original = config.read_text()
    # Strip only our exact generated prefix(es) to keep repeated runs stable.
    headers = {'pubkeyauthentication yes','authenticationmethods publickey','passwordauthentication no','kbdinteractiveauthentication no','challengeresponseauthentication no'}
    rest = original.splitlines(keepends=True)
    while rest and rest[0].strip() == '# Managed key-only SSH policy':
        rest.pop(0)
        while rest and rest[0].strip().lower() in headers: rest.pop(0)
    (w/'sshd_config').write_text(policy + ''.join(rest))
    paths = [config, sshdir, auth]
    state = {'files': {}, 'observed': seen, 'uid': uid, 'gid': gid, 'auth': str(auth), 'sshdir':str(sshdir), 'config':str(config)}
    if alternate.exists(): state['observed'][str(alternate)] = digest(alternate)
    for path in paths:
        if path.exists():
            st = path.stat(); info = {'exists':True,'mode':stat.S_IMODE(st.st_mode),'uid':st.st_uid,'gid':st.st_gid,'directory':path.is_dir()}
            if not path.is_dir(): info['digest'] = digest(path)
        else: info = {'exists':False}
        state['files'][str(path)] = info
    (w/'state.json').write_text(json.dumps(state))

def snapshot(work, backup):
    w = pathlib.Path(work); b = pathlib.Path(backup); state = json.loads((w/'state.json').read_text())
    for name, expected in state['observed'].items():
        if digest(name) != expected: fail('检查后配置发生变化，停止: ' + name)
    for name, info in state['files'].items():
        p=pathlib.Path(name)
        if p.exists() != info['exists']: fail('检查后文件状态发生变化: ' + name)
        if info['exists']:
            st=p.stat()
            if p.is_symlink() or (stat.S_IMODE(st.st_mode),st.st_uid,st.st_gid)!=(info['mode'],info['uid'],info['gid']): fail('检查后权限变化: ' + name)
            if not info['directory'] and digest(p)!=info['digest']: fail('检查后内容发生变化: ' + name)
    for label in ('config','auth'):
        source = pathlib.Path(state[label])
        if source.exists(): shutil.copyfile(str(source), str(b/label))
    shutil.copyfile(str(w/'state.json'),str(b/'state.json'))

def restore(backup):
    b=pathlib.Path(backup); state=json.loads((b/'state.json').read_text())
    for label in ('config','auth'):
        path=pathlib.Path(state[label]); info=state['files'][str(path)]
        if info['exists']:
            shutil.copyfile(str(b/label),str(path)); os.chown(str(path),info['uid'],info['gid']); os.chmod(str(path),info['mode'])
        elif path.exists(): path.unlink()
    directory=pathlib.Path(state['sshdir']); info=state['files'][str(directory)]
    if info['exists']:
        os.chown(str(directory),info['uid'],info['gid']); os.chmod(str(directory),info['mode'])
    elif directory.exists():
        try: directory.rmdir()
        except OSError: pass  # Never remove unrelated files.

if __name__ == '__main__':
    try:
        mode = sys.argv[1]
        if mode == 'audit': audit(sys.argv[2],sys.argv[3],sys.argv[4],int(sys.argv[5]),int(sys.argv[6]),sys.argv[7])
        elif mode == 'verify': verify_policy(sys.argv[2])
        elif mode == 'snapshot': snapshot(sys.argv[2],sys.argv[3])
        elif mode == 'restore': restore(sys.argv[2])
        else: fail('未知操作')
    except Exception as exc:
        print('检查/恢复失败：' + str(exc), file=sys.stderr); sys.exit(1)
PY_HELPER
python3 "$tmp/helper.py" audit "$tmp" "$target" "$home" "$uid" "$gid" "$config" \
  || die '预检查未通过；未修改公钥和 SSH 配置'
"$sshd" -t -f "$tmp/sshd_config" || die '候选配置校验失败；未修改'
"$sshd" -T -f "$tmp/sshd_config" > "$tmp/candidate-effective"
python3 "$tmp/helper.py" verify "$tmp/candidate-effective" || die '候选有效配置未通过；未修改'
choice=keep
old_count=$(cat "$tmp/old-count")
if [[ $old_count -gt 0 ]]; then
  [[ -t 0 ]] || die '存在旧公钥但无交互终端；请下载脚本后在 SSH/VNC 终端运行'
  printf '是否删除用户 %s 的上述旧公钥，仅保留当前公钥？输入 yes 删除；直接回车或输入 no 保留：' "$target"
  IFS= read -r answer || die '未收到回答；未修改公钥和 SSH 配置'
  case "$answer" in
    yes) choice=replace ;;
    no|'') choice=keep ;;
    *) die '无法识别回答，只接受 yes、no 或回车；未修改' ;;
  esac
fi
backup_dir=$(mktemp -d /etc/ssh/key-only-backup.XXXXXXXX)
cp "$tmp/helper.py" "$backup_dir/helper.py"
python3 "$tmp/helper.py" snapshot "$tmp" "$backup_dir" || die '备份/并发检查失败；未修改'
rollback=$backup_dir/rollback.sh
printf '#!/bin/bash\nset -euo pipefail\nexport PATH=/usr/sbin:/usr/bin:/sbin:/bin\npython3 %q restore %q\n/usr/sbin/sshd -t\nsystemctl reload %q\n' \
  "$backup_dir/helper.py" "$backup_dir" "$unit" > "$rollback"
chmod 700 "$rollback"
printf '备份完成。手动恢复（root 执行）：bash %s\n' "$rollback"
rollback_on_error() {
  trap - ERR HUP INT TERM
  if /bin/bash "$rollback"; then
    echo '操作失败/中断，已恢复本次执行前的公钥、权限和 SSH 配置。' >&2
  else
    printf '自动恢复失败，请通过当前连接或控制台执行：bash %s\n' "$rollback" >&2
  fi
  exit 1
}
trap rollback_on_error ERR HUP INT TERM
mkdir -p -- "$home/.ssh"
chown "$uid:$gid" "$home/.ssh"
chmod 700 "$home/.ssh"
cat "$tmp/keys.$choice" > "$home/.ssh/authorized_keys"
chown "$uid:$gid" "$home/.ssh/authorized_keys"
chmod 600 "$home/.ssh/authorized_keys"
cat "$tmp/sshd_config" > "$config"
"$sshd" -t
systemctl reload "$unit"
systemctl is-active --quiet "$unit"
"$sshd" -T > "$tmp/applied"
python3 "$tmp/helper.py" verify "$tmp/applied"
trap - ERR HUP INT TERM
printf '\n完成：%s 的公钥已配置，SSH 全局仅允许公钥认证，永久生效。\n' "$target"
printf '旧公钥处理：%s；恢复命令：bash %s\n' "$choice" "$rollback"
printf '请保留当前连接，另开终端测试。脚本无法验证客户端持有私钥，也不修改其他用户的公钥。\n'
