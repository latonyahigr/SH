#!/usr/bin/env bash
# Install one Ed25519 public key for an existing Linux user.
# Usage: bash install-general-key.sh [username] [path/to/general.pub]
# Without a file argument, use the embedded general public key.
set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
[[ $EUID == 0 ]] || { echo "请使用 sudo bash 或 root 执行。" >&2; exit 1; }
umask 077
die() { printf '错误：%s\n' "$*" >&2; exit 1; }
[[ $# -le 2 ]] || die '用法：bash install-general-key.sh [用户名] [公钥文件]'
for tool in getent ssh-keygen mktemp awk flock; do
  command -v "$tool" >/dev/null || die "缺少命令：$tool，请先安装对应系统软件包。"
done
target=${1:-${SUDO_USER:-$(id -un)}}
entry=$(getent passwd "$target") || die "用户不存在：$target"
IFS=: read -r account unused uid gid gecos home login_shell <<< "$entry"
[[ $account == "$target" && $home == /* && -d $home ]] || die '用户或 home 目录无效'
[[ $EUID == 0 || $EUID == "$uid" ]] || die '操作其他用户需要 root/sudo 权限'
[[ ! -L $home ]] || die '为避免写入错误位置，不支持符号链接 home'
printf '安装 general 公钥到用户：%s\n目标：%s/.ssh/authorized_keys\n' "$target" "$home"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
if [[ $# == 2 ]]; then
  [[ -f $2 && -r $2 ]] || die '公钥文件不存在或不可读'
  cp -- "$2" "$tmp/input"
else
  # Public key only: safe to distribute; never embed a private key here.
  printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOY/BZiIF8fG9MDUF/gvE6+P2wYjAqQIVnyBTEoqG2Pz' > "$tmp/input"
  printf '使用脚本内置的 general 公钥。\n'
fi
# Accept exactly one plain Ed25519 public key; reject private keys and options.
awk 'NF {sub(/\r$/, ""); n++; if (NF < 2 || $1 != "ssh-ed25519") bad=1;
  print $1 " " $2 " vps-general"} END {if (n != 1 || bad) exit 1}' \
  "$tmp/input" > "$tmp/key" || die '必须提供一把 Ed25519 公钥，不能提供私钥或多把公钥'
ssh-keygen -lf "$tmp/key" -E sha256 || die '公钥格式无效'
printf '请与 Bitwarden 中 general 的指纹核对。确认安装请输入 yes：' > /dev/tty
IFS= read -r answer < /dev/tty || die '未确认'
[[ $answer == yes ]] || die '已取消，未修改 SSH 配置'
ssh_dir=$home/.ssh
auth=$ssh_dir/authorized_keys
[[ ! -L $ssh_dir && ! -L $auth ]] || die '拒绝修改符号链接 .ssh/authorized_keys'
[[ ! -e $ssh_dir || -d $ssh_dir ]] || die '.ssh 不是目录'
[[ ! -e $auth || -f $auth ]] || die 'authorized_keys 不是普通文件'
mkdir -p -- "$ssh_dir"
[[ $EUID != 0 ]] || chown "$uid:$gid" "$ssh_dir"
chmod 700 "$ssh_dir"
# Lock the directory, without leaving a lock file; serialize this installer.
exec 9< "$ssh_dir"
flock -x 9
blob=$(awk '{print $2}' "$tmp/key")
# Also recognize a matching key with existing restrictions; do not bypass them.
if [[ -f $auth ]] && awk -v b="$blob" '
  /^[[:space:]]*#/ {next} {for(i=1;i<NF;i++) if($i=="ssh-ed25519" && $(i+1)==b) found=1}
  END {exit !found}' "$auth"; then
  printf '此公钥已经存在，保留现有条目及限制，不重复添加。\n'
else
if [[ -f $auth ]]; then
  backup=$(mktemp "$ssh_dir/authorized_keys.backup.XXXXXXXX")
  cp -p -- "$auth" "$backup"
  chmod 600 "$backup"
  printf '旧配置备份：%s\n' "$backup"
fi
# Append in place; keep existing entries and their restrictions.
{ printf '\n'; cat "$tmp/key"; } >> "$auth"
[[ $EUID != 0 ]] || chown "$uid:$gid" "$auth"
chmod 600 "$auth"
if command -v restorecon >/dev/null; then
  restorecon "$ssh_dir" "$auth" || printf '提示：请检查 SELinux 文件标签。\n' >&2
fi
fi
flock -u 9
printf '\n公钥已就绪。接下来将全局限制 SSH 仅允许公钥认证。\n'
for tool in python3 systemctl systemd-run; do
  command -v "$tool" >/dev/null || die "缺少 $tool；未修改 SSH 服务配置。"
done
sshd=/usr/sbin/sshd
config=/etc/ssh/sshd_config
[[ -x $sshd && -f $config && ! -L $config ]] || die '不支持此 SSH 安装路径或符号链接配置'
exec 8< /etc/ssh
flock -n -x 8 || die '另一实例正在修改 SSH 配置'
unit=
for candidate in ssh.service sshd.service; do
  if systemctl is-active --quiet "$candidate"; then unit=$candidate; break; fi
done
[[ -n $unit ]] || die '未找到运行中的 systemd SSH 服务；未修改配置'
[[ $(systemctl show "$unit" -p CanReload --value) == yes ]] || die 'SSH 服务不支持 reload；停止以避免重启'
# Refuse custom daemon arguments: -f/-o could override the file we validate.
pid=$(systemctl show "$unit" -p MainPID --value)
python3 - "$pid" <<'PY_CHECK_PROCESS' || die '检测到自定义 SSH 启动参数，请人工检查'
import pathlib, sys
args = pathlib.Path('/proc/' + sys.argv[1] + '/cmdline').read_bytes().split(b'\0')
text = b' '.join(args).decode(errors='replace')
if '-f' in text or '-o' in text:
    raise SystemExit(1)
PY_CHECK_PROCESS
# Conservatively refuse Match blocks (including included files); do not weaken
# or silently bypass site-specific authentication policies.
python3 - "$config" <<'PY_CHECK_CONFIG' || die '存在 Match、自定义认证策略或不可解析配置；未修改配置'
import glob, pathlib, shlex, sys
seen = set()
def scan(name):
    path = pathlib.Path(name).resolve()
    if path in seen: return
    seen.add(path)
    for line in path.read_text().splitlines():
        words = shlex.split(line, comments=True)
        if not words: continue
        key = words[0].lower()
        if key == 'match':
            raise ValueError('发现 Match 块: ' + str(path))
        if key == 'authenticationmethods' and words[1:] not in (['any'], ['publickey']):
            raise ValueError('保留现有多因素认证策略: ' + str(path))
        if key == 'include':
            for pattern in words[1:]:
                if not pattern.startswith('/'): pattern = '/etc/ssh/' + pattern
                for child in sorted(glob.glob(pattern)): scan(child)
scan(sys.argv[1])
PY_CHECK_CONFIG
"$sshd" -t || die '原有 SSH 配置校验失败，未修改'
printf '请保留此连接，在另一个终端使用 general 私钥成功登录用户 %s。\n' "$target"
printf '确认已用密钥登录成功，且控制台可救援后，输入 KEY-LOGIN-OK：' > /dev/tty
IFS= read -r answer < /dev/tty || die '未确认'
[[ $answer == KEY-LOGIN-OK ]] || die '已取消关闭密码登录，公钥仍保留'
backup_dir=$(mktemp -d /etc/ssh/key-only-backup.XXXXXXXX)
cp -p "$config" "$backup_dir/sshd_config"
# Prepend global values: OpenSSH uses the first obtained global value.
{
  printf '# Managed key-only SSH policy\nPubkeyAuthentication yes\nAuthenticationMethods publickey\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nChallengeResponseAuthentication no\n'
  cat "$config"
} > "$tmp/sshd_config"
"$sshd" -t -f "$tmp/sshd_config" || die '新配置校验失败，原配置未修改'
"$sshd" -T -f "$tmp/sshd_config" > "$tmp/effective"
for expected in 'pubkeyauthentication yes' 'authenticationmethods publickey' 'passwordauthentication no' 'kbdinteractiveauthentication no'; do
  grep -qx "$expected" "$tmp/effective" || die "有效配置不符合预期：$expected"
done
# A scheduled rollback survives terminal disconnects. Rebooting before KEEP
# is not supported, so preserve the printed manual recovery command.
rollback=$backup_dir/rollback.sh
printf '#!/bin/bash\nset -eu\ncp -p %q %q\n/usr/sbin/sshd -t\nsystemctl reload %q\n' \
  "$backup_dir/sshd_config" "$config" "$unit" > "$rollback"
chmod 700 "$rollback"
printf '手动恢复命令（当前连接或 VNC 中以 root 执行）：\nbash %s\n' "$rollback"
timer="ssh-key-rollback-${backup_dir##*.}"
systemd-run --unit="$timer" --on-active=180s --timer-property=AccuracySec=1s /bin/bash "$rollback" \
  || die '无法安排自动恢复，未修改配置'
rollback_on_error() {
  trap - ERR HUP INT TERM
  /bin/bash "$rollback" || true
  systemctl stop "$timer.timer" || true
  echo '操作失败/中断，已尝试恢复原 SSH 配置。' >&2
  exit 1
}
trap rollback_on_error ERR HUP INT TERM
cat "$tmp/sshd_config" > "$config"
"$sshd" -t
systemctl reload "$unit"
printf '\n已重载：仅允许公钥认证，密码及交互式认证已关闭。\n'
printf '请现在再次新建 SSH 连接测试。180 秒后自动恢复原配置。不要重启服务器。\n'
printf '新连接成功后，120 秒内在这里输入 KEEP 保留配置：' > /dev/tty
answer=
if IFS= read -r -t 120 answer < /dev/tty && [[ $answer == KEEP ]]; then
  systemctl stop "$timer.timer"
  if systemctl is-active --quiet "$timer.service" || systemctl is-failed --quiet "$timer.service"; then
    rollback_on_error
  fi
  # Refuse success if the timer already restored the old config.
  cmp -s "$config" "$tmp/sshd_config" || rollback_on_error
  trap - ERR HUP INT TERM
  printf '已保留仅密钥登录配置。备份及恢复脚本：%s\n' "$backup_dir"
else
  rollback_on_error
fi
