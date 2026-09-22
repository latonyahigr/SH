#!/usr/bin/env bash
# Install one Ed25519 public key for an existing Linux user.
# Usage: bash install-general-key.sh [username] [path/to/general.pub]
# Without a file argument, paste the public key from Bitwarden/private GitHub.
set -euo pipefail
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
  printf '请粘贴 general.pub 的完整一行（ssh-ed25519 开头），然后回车：\n' > /dev/tty
  IFS= read -r key < /dev/tty || die '读取公钥失败'
  printf '%s\n' "$key" > "$tmp/input"
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
  exit 0
fi
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
printf '\n公钥已安装。未修改 sshd 配置、密码登录、防火墙或重启服务。\n'
printf '请保留当前连接，另开终端使用 general 私钥登录 %s 验证。\n' "$target"
printf '如果 sshd 使用自定义 AuthorizedKeysFile 或禁止该用户登录，还需单独检查配置。\n'
