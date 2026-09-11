#!/usr/bin/env bash
set -Eeuo pipefail

# Debian/Ubuntu SOCKS5 one-click installer (Dante)
# Values can be overridden, e.g. SOCKS_PASSWORD='new-password' bash install-socks5.sh
SOCKS_PORT="${SOCKS_PORT:-8090}"
SOCKS_USER="${SOCKS_USER:-kaer}"
SOCKS_PASSWORD="${SOCKS_PASSWORD:-Aa013579.@}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Error: please run this script as root."
  exit 1
fi

if [[ ! -r /etc/os-release ]]; then
  echo "Error: cannot identify the operating system."
  exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release
case "${ID:-}" in
  debian|ubuntu) ;;
  *)
    echo "Error: only Debian and Ubuntu are supported (current: ${ID:-unknown})."
    exit 1
    ;;
esac

if ! [[ "$SOCKS_PORT" =~ ^[0-9]+$ ]] || (( SOCKS_PORT < 1 || SOCKS_PORT > 65535 )); then
  echo "Error: invalid SOCKS_PORT: $SOCKS_PORT"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y dante-server curl ca-certificates

OUT_IF="$(ip -4 route show default | awk 'NR==1 {print $5}')"
if [[ -z "$OUT_IF" ]]; then
  echo "Error: no default IPv4 network interface was found."
  exit 1
fi

if id "$SOCKS_USER" >/dev/null 2>&1; then
  usermod --shell /usr/sbin/nologin "$SOCKS_USER"
else
  useradd --system --no-create-home --shell /usr/sbin/nologin "$SOCKS_USER"
fi
printf '%s:%s\n' "$SOCKS_USER" "$SOCKS_PASSWORD" | chpasswd

if [[ -f /etc/danted.conf ]]; then
  cp -a /etc/danted.conf "/etc/danted.conf.bak.$(date +%Y%m%d%H%M%S)"
fi

install -m 600 /dev/null /etc/danted.conf
cat >/etc/danted.conf <<EOF
logoutput: syslog
internal: 0.0.0.0 port = ${SOCKS_PORT}
external: ${OUT_IF}

socksmethod: username
clientmethod: none

user.privileged: proxy
user.notprivileged: nobody

client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect disconnect error
}

socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    command: connect bind udpassociate
    socksmethod: username
    log: connect disconnect error
}
EOF

systemctl enable danted
systemctl restart danted

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
  ufw allow "${SOCKS_PORT}/tcp" comment 'SOCKS5 Dante' >/dev/null
fi

if ! systemctl is-active --quiet danted; then
  echo "Error: danted failed to start. Recent logs:"
  journalctl -u danted --no-pager -n 30
  exit 1
fi

PUBLIC_IP="$(curl -4fsS --max-time 8 https://api.ipify.org || true)"
if [[ -z "$PUBLIC_IP" ]]; then
  PUBLIC_IP="$(hostname -I | awk '{print $1}')"
fi

cat <<EOF

SOCKS5 deployment completed successfully.
IP:       ${PUBLIC_IP}
Port:     ${SOCKS_PORT}
Username: ${SOCKS_USER}
Password: ${SOCKS_PASSWORD}

Service status: systemctl status danted --no-pager
View logs:      journalctl -u danted -n 50 --no-pager
EOF
