#!/usr/bin/env bash
# Debian 12 / 13: migrate a Docker or systemd Beszel hub to Komari.
# Usage: bash komari-install.sh panel | bash komari-install.sh agent
set -Eeuo pipefail
umask 077
MODE="${1:-panel}"
ENDPOINT="https://jiankong.845788.xyz"
BASE=/opt/komari
IMAGE=ghcr.io/komari-monitor/komari:1.6.1
die() { echo "错误：$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die '请使用 root 执行。'
[[ $MODE == panel || $MODE == agent ]] || die '参数只能是 panel 或 agent。'
. /etc/os-release
[[ ${ID:-} == debian && ( ${VERSION_ID:-} == 12 || ${VERSION_ID:-} == 13 ) ]] || die '此脚本仅用于 Debian 12 / Debian 13。'
command -v flock >/dev/null || die '缺少 flock，请先安装 util-linux。'
exec 9>/run/lock/komari-install.lock
flock -n 9 || die '另一个部署任务正在运行。'
if ! command -v curl >/dev/null || ! command -v python3 >/dev/null; then
  apt-get update
  apt-get install -y curl ca-certificates python3
fi

panel() {
  command -v docker >/dev/null || die '未发现 Docker。请先在宝塔安装 Docker 后重试。'
  docker info >/dev/null
  # EXIT traps run after function scopes unwind on an unhandled failure.
  # Keep rollback state at script scope so restoration also works with set -e.
  old_id='' old_running='' old_restart='' backup='' image_id=''
  old_unit='' old_enabled='' host_changed=0
  changed=0 new_created=0 committed=0
  if docker container inspect komari >/dev/null 2>&1; then
    die '已存在 komari 容器；为避免覆盖已有安装，请先执行 docker ps -a 检查。'
  fi
  if [[ -e $BASE ]]; then
    # The old installer can leave only inspection records after a port-check
    # failure. Archive exactly that state; never replace existing Komari data.
    python3 - "$BASE" <<'PY'
from pathlib import Path
import json, sys
p = Path(sys.argv[1])
if p.is_symlink() or not p.is_dir() or {x.name for x in p.iterdir()} != {'beszel-backup'}:
    sys.exit('目录已有数据，拒绝覆盖：' + str(p))
b = p / 'beszel-backup'
if b.is_symlink() or not b.is_dir():
    sys.exit('备份目录不符合预期，拒绝覆盖。')
items = list(b.iterdir())
if not items or any(x.is_symlink() or not x.is_file() or x.name not in {'containers-before.json', 'beszel-inspect.json'} for x in items):
    sys.exit('目录不符合此前端口检查失败的状态，拒绝覆盖。')
for x in items:
    json.loads(x.read_text())
PY
    archive="${BASE}-failed-$(date +%Y%m%d-%H%M%S)-$$"
    [[ ! -e $archive ]] || die '归档目录已存在。'
    mv -- "$BASE" "$archive"
    echo "已保留上次失败记录：$archive"
  fi
  # Only the exact Beszel hub image is eligible, never beszel-agent or an
  # arbitrary service whose container name happens to contain beszel.
  local ids inventory selected
  ids="$(docker ps -aq)"
  inventory="$(mktemp)"
  if [[ -n $ids ]]; then
    # Docker container IDs contain no spaces or shell metacharacters.
    # shellcheck disable=SC2086
    docker inspect $ids > "$inventory"
  else
    printf '[]\n' > "$inventory"
  fi
  if ! selected="$(python3 - "$inventory" <<'PY'
import json, sys
containers = json.load(open(sys.argv[1]))
matches = []
for c in containers:
    bindings = c.get('HostConfig', {}).get('PortBindings') or {}
    if not any(str(b.get('HostPort')) == '7070'
               for group in bindings.values() for b in (group or [])):
        continue
    image = c['Config']['Image'].split('@')[0].split(':')[0]
    if image.rsplit('/', 1)[-1] != 'beszel':
        sys.exit('7070 被非 Beszel 容器占用或预留，已停止操作。')
    matches.append(c)
if len(matches) > 1:
    sys.exit('发现多个使用 7070 的 Beszel 容器，已停止操作。')
if matches:
    c = matches[0]
    p = c['HostConfig']['RestartPolicy']
    restart = p['Name'] or 'no'
    if restart == 'on-failure' and p.get('MaximumRetryCount', 0):
        restart += ':' + str(p['MaximumRetryCount'])
    print(c['Id'], str(c['State']['Running']).lower(), restart)
PY
  )"; then
    rm -f "$inventory"
    die '容器检查未通过；没有停止任何容器。'
  fi
  if [[ -n $selected ]]; then
    read -r old_id old_running old_restart <<< "$selected"
  else
    # A native Beszel hub has no Docker port mapping. Resolve the listener's
    # executable, dedicated systemd unit, MainPID and enable state before
    # granting this installer permission to stop anything on the host.
    command -v ss >/dev/null || die '缺少 ss，请安装 iproute2。'
    local listeners native
    listeners="$(ss -H -lntp '( sport = :7070 )')"
    native="$(python3 - "$listeners" <<'PY'
from pathlib import Path
import re, subprocess, sys
raw = sys.argv[1].strip()
if not raw:
    sys.exit(0)
pids = set(re.findall(r'pid=(\d+)', raw))
if len(pids) != 1:
    sys.exit('7070 监听进程不唯一或无法识别，未停止服务。')
pid = next(iter(pids))
exe = Path('/proc', pid, 'exe').resolve(strict=True)
if exe.name != 'beszel':
    sys.exit('7070 不是 Beszel 主程序，未停止服务。')
cgroup = Path('/proc', pid, 'cgroup').read_text()
units = set(re.findall(r':/system\.slice/([^/\n]+\.service)(?:\n|$)', cgroup))
if len(units) != 1:
    sys.exit('Beszel 不属于可确认的独立 systemd 服务，未停止；请反馈 systemctl status ' + pid)
unit = next(iter(units))
def prop(key):
    return subprocess.check_output(['systemctl', 'show', unit, '-p', key, '--value'], text=True).strip()
if prop('MainPID') != pid or prop('TriggeredBy'):
    sys.exit('服务不是 Beszel 独立主进程，或存在自动激活源，未停止。')
enabled = prop('UnitFileState')
if enabled not in {'enabled', 'disabled'}:
    sys.exit('服务启用方式需人工确认：' + unit + ' ' + enabled)
print(unit, enabled)
PY
    )"
    if [[ -n $native ]]; then
      read -r old_unit old_enabled <<< "$native"
      echo "识别到宿主机 Beszel 服务：$old_unit"
    fi
  fi
  echo '[1/5] 拉取固定版本镜像；此阶段不停止 Beszel...'
  docker pull "$IMAGE"
  image_id="$(docker image inspect --format '{{.Id}}' "$IMAGE")"
  [[ $image_id == sha256:* ]] || die '镜像 ID 无效。'
  install -d -m 0700 "$BASE"
  backup="$BASE/beszel-backup"
  install -d -m 0700 "$backup"
  mv "$inventory" "$backup/containers-before.json"
  chmod 0600 "$backup/containers-before.json"
  # Keep the original Beszel volume/bind data in place, including anonymous volumes.
  # Root-only inspection records preserve its original mounts and configuration.
  if [[ -n $old_id ]]; then
    docker inspect "$old_id" > "$backup/beszel-inspect.json"
  fi
  if [[ -n $old_unit ]]; then
    systemctl cat "$old_unit" > "$backup/beszel-unit.txt"
    systemctl show "$old_unit" > "$backup/beszel-unit-properties.txt"
    printf '%s %s\n' "$old_unit" "$old_enabled" > "$backup/beszel-unit-state.txt"
  fi
  rollback() {
    local rc=$?
    trap - EXIT
    if (( rc != 0 && committed == 0 )); then
      echo '部署失败，尝试恢复原 Beszel 容器...' >&2
      if (( new_created )); then
        docker logs komari > "$backup/komari-failed.log" 2>&1 || true
        docker rm -f komari >/dev/null 2>&1 || true
      fi
      if (( changed )) && [[ -n $old_id ]]; then
        docker update --restart="$old_restart" "$old_id" >/dev/null 2>&1 || true
        if [[ $old_running == true ]]; then docker start "$old_id" >/dev/null 2>&1 || true; fi
      fi
      if (( host_changed )) && [[ -n $old_unit ]]; then
        if [[ $old_enabled == enabled ]]; then systemctl enable "$old_unit" >/dev/null 2>&1 || true; fi
        systemctl start "$old_unit" >/dev/null 2>&1 || true
      fi
      echo "检查记录：$BASE；未删除 Beszel 数据。" >&2
    fi
    exit "$rc"
  }
  trap rollback EXIT
  echo '[2/5] 停止旧 Beszel（保留原数据）...'
  if [[ -n $old_id ]]; then
    changed=1
    docker update --restart=no "$old_id" >/dev/null
    docker stop -t 30 "$old_id" >/dev/null
  fi
  if [[ -n $old_unit ]]; then
    host_changed=1
    systemctl stop "$old_unit"
  fi
  # Probe host-side port occupancy before starting the replacement.
  python3 - <<'PY'
import socket
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind(('127.0.0.1', 7070))
except OSError:
    raise SystemExit('本机 7070 仍被占用，请检查其他进程。')
finally:
    s.close()
PY
  echo '[3/5] 创建 Komari，仅监听 127.0.0.1:7070...'
  install -d -o 65532 -g 65532 -m 0750 "$BASE/data" "$BASE/cache"
  # The parent must be traversable for non-root container bind mounts.
  chmod 0711 "$BASE"
  docker create --name komari \
    --restart unless-stopped \
    --user 65532:65532 \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --label com.centurylinklabs.watchtower.enable=false \
    --label local.komari.installer=jiankong \
    --log-opt max-size=10m --log-opt max-file=3 \
    -e TZ=Asia/Shanghai \
    -p 127.0.0.1:7070:25774 \
    -v "$BASE/data:/app/data" \
    -v "$BASE/cache:/app/cache" \
    "$image_id" >/dev/null
  new_created=1
  docker start komari >/dev/null
  echo '[4/5] 等待 HTTP 服务就绪...'
  local ready=0 code=''
  for ((i=0; i<45; i++)); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:7070/ || true)"
    if [[ $code =~ ^[23][0-9][0-9]$ ]]; then ready=1; break; fi
    sleep 2
  done
  if (( ! ready )); then
    echo 'Komari 未就绪。请在本机检查：docker logs komari' >&2
    exit 1
  fi
  echo '[5/5] 完成替换，移除旧 Beszel 容器（不删除卷和原数据）...'
  if [[ -n $old_unit && $old_enabled == enabled ]]; then
    systemctl disable "$old_unit"
  fi
  if [[ -n $old_id ]]; then docker rm "$old_id" >/dev/null; fi
  committed=1
  printf '%s\n' "$IMAGE" "$image_id" > "$BASE/installed-image.txt"
  cat <<TXT

Komari 已启动。宝塔反向代理设置：
域名：jiankong.845788.xyz
目标 URL：http://127.0.0.1:7070
发送域名：\$host
开启 WebSocket，关闭代理缓存，申请 SSL 并强制 HTTPS。
访问 $ENDPOINT 完成初始化，启用管理员双重验证。
数据：$BASE/data
原 Beszel 数据未删除；容器配置记录：$backup
原宿主机 Beszel 服务（如有）已停止并关闭开机启动，程序及数据保留。
旧 Beszel Agent 不会自动迁移或卸载；后续逐台替换。

注意：面板部署不等于禁用节点控制。添加节点时必须使用本脚本 agent 模式。
TXT
  trap - EXIT
}

agent() {
  local svc=komari-monitor arch sha tmp token account_groups
  for existing in komari-agent.service komari-monitor.service; do
    if systemctl cat "$existing" >/dev/null 2>&1; then
      die "已存在 $existing；为避免双 Agent 或覆盖配置，请先检查。"
    fi
  done
  [[ ! -e /etc/komari-monitor && ! -e /usr/local/bin/komari-agent ]] || die '发现现有 Agent 文件，请先检查，未覆盖。'
  curl -fsS --connect-timeout 10 --max-time 20 -o /dev/null "$ENDPOINT/" || die 'HTTPS 未就绪，请先完成宝塔反代和 SSL。'
  read -r -s -p '粘贴这台节点的 Token（输入不显示）：' token </dev/tty
  echo
  [[ $token =~ ^[A-Za-z0-9_-]+$ ]] || die 'Token 为空或格式不正确。'
  case "$(uname -m)" in
    x86_64) arch=amd64; sha=78c28d89e523816baea010c0ed0714f245f508ffdaca0540f5c9f230f7053c8c ;;
    aarch64|arm64) arch=arm64; sha=ff8e33dc12ef2b5738fa291a58498bd15dcbf8ef51966ab65fd67679a0abc87d ;;
    *) die '仅支持 AMD64 / ARM64。' ;;
  esac
  tmp="$(mktemp -d)"
  AGENT_TMP="$tmp"
  trap 'rm -rf "$AGENT_TMP"' EXIT
  curl -fL --retry 3 --connect-timeout 15 --max-time 300 \
    "https://github.com/komari-monitor/komari-agent/releases/download/1.5.11/komari-agent-linux-$arch" \
    -o "$tmp/komari-agent"
  printf '%s  %s\n' "$sha" "$tmp/komari-agent" | sha256sum -c -
  if id komari-monitor >/dev/null 2>&1; then
    [[ $(id -u komari-monitor) != 0 ]] || die 'Agent 用户不能是 root。'
    account_groups="$(id -nG komari-monitor)"
    [[ $account_groups == komari-monitor ]] || die '现有 Agent 用户有额外组权限，已停止。'
  else
    useradd --system --user-group --home-dir /var/lib/komari-monitor \
      --no-create-home --shell /usr/sbin/nologin komari-monitor
  fi
  install -o root -g root -m 0755 "$tmp/komari-agent" /usr/local/bin/komari-agent
  install -d -o root -g root -m 0700 /etc/komari-monitor
  printf 'AGENT_ENDPOINT=%s\nAGENT_TOKEN=%s\n' "$ENDPOINT" "$token" > /etc/komari-monitor/agent.env
  chmod 0600 /etc/komari-monitor/agent.env
  unset token
  cat > /etc/systemd/system/komari-monitor.service <<'UNIT'
[Unit]
Description=Komari monitoring agent
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=komari-monitor
Group=komari-monitor
EnvironmentFile=/etc/komari-monitor/agent.env
ExecStart=/usr/local/bin/komari-agent --disable-web-ssh --disable-auto-update
Restart=on-failure
RestartSec=5
StateDirectory=komari-monitor
StateDirectoryMode=0700
WorkingDirectory=/var/lib/komari-monitor
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
CapabilityBoundingSet=
AmbientCapabilities=
UMask=0077

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now "$svc"
  sleep 3
  systemctl is-active --quiet "$svc" || die '服务未运行，请执行 journalctl -u komari-monitor -n 50 --no-pager 检查。'
  rm -rf "$tmp"
  trap - EXIT
  echo 'Agent 服务已运行；普通用户、远程控制关闭、自动更新关闭。'
  echo '请在面板确认节点在线，并验证终端、命令执行及文件操作被拒绝。'
  echo '部分指标、ICMP 探测可能受权限限制，不要直接改成 root。'
}

"$MODE"
