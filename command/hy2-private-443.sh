#!/usr/bin/env bash
# HY2 Debian 12/13 interactive installer - UDP 443 + Salamander
set -Eeuo pipefail
umask 077

log() { printf '\n[HY2] %s\n' "$*"; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "请使用 root 执行"
[[ -r /etc/os-release ]] || die "无法识别系统"
. /etc/os-release
[[ "${ID:-}" == debian && "${VERSION_ID%%.*}" -ge 12 ]] || die "仅支持 Debian 12 及以上"
[[ -t 0 ]] || die "请在 SSH 交互终端执行（不能用 curl | bash）"

read -r -p "HY2 域名（已解析到 VPS）: " DOMAIN
[[ "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && "$DOMAIN" == *.* && "$DOMAIN" != *..* ]] || die "域名格式无效"
DOMAIN="${DOMAIN,,}"
printf '证书方式：1=自动 ACME HTTP-01（TCP 80 必须空闲）  2=现有证书文件\n'
read -r -p "请选择 [1/2，默认1]: " CERT_MODE
CERT_MODE="${CERT_MODE:-1}"
[[ "$CERT_MODE" == 1 || "$CERT_MODE" == 2 ]] || die "无效选择"

EMAIL="" CERT_PATH="" KEY_PATH=""
if [[ "$CERT_MODE" == 1 ]]; then
  read -r -p "ACME 邮箱: " EMAIL
  [[ "$EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die "邮箱格式无效"
else
  read -r -p "证书 fullchain.pem 绝对路径: " CERT_PATH
  read -r -p "私钥 privkey.pem 绝对路径: " KEY_PATH
  [[ "$CERT_PATH" == /* && "$KEY_PATH" == /* && -s "$CERT_PATH" && -s "$KEY_PATH" ]] || die "证书文件不存在或为空"
fi

read -r -p "认证密码（回车自动生成）: " AUTH_PASS
read -r -p "Salamander 混淆密码（回车自动生成）: " OBFS_PASS
AUTH_PASS="${AUTH_PASS:-$(openssl rand -hex 24 2>/dev/null || true)}"
OBFS_PASS="${OBFS_PASS:-$(openssl rand -hex 24 2>/dev/null || true)}"
[[ "${#AUTH_PASS}" -ge 16 && "${#OBFS_PASS}" -ge 16 && "$AUTH_PASS" != "$OBFS_PASS" ]] || die "两组密码必须不同且各至少16字符"
[[ "$AUTH_PASS" =~ ^[A-Za-z0-9._~-]+$ && "$OBFS_PASS" =~ ^[A-Za-z0-9._~-]+$ ]] || die "密码只允许字母、数字及 . _ ~ -（避免 YAML 转义问题）"

log "安装依赖和检查端口"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates openssl iproute2 dnsutils >/dev/null

if ss -H -lunp | awk '{print $5}' | grep -Eq '(^|:)443$'; then
  # An existing HY2 service is allowed to restart; other UDP 443 listeners are not.
  UDP_HOLDERS="$(ss -H -lunp | grep -E '(:443)[[:space:]]' || true)"
  if [[ "$UDP_HOLDERS" != *hysteria* ]]; then
    printf '%s\n' "$UDP_HOLDERS"
    die "UDP 443 已被占用，请先处理（没有自动停止任何服务）"
  fi
fi

if [[ "$CERT_MODE" == 1 ]] && ss -H -lnt | awk '{print $4}' | grep -Eq '(^|:)80$'; then
  die "TCP 80 被占用；请选择已有证书方式，或先自行调整占用 TCP 80 的服务"
fi

PUBLIC_IP="$(curl -4fsS --max-time 8 https://api.ipify.org || true)"
DNS_IPS="$(dig +short A "$DOMAIN" | grep -E '^[0-9]+(\.[0-9]+){3}$' || true)"
printf '公网 IP: %s\n域名 A 记录:\n%s\n' "${PUBLIC_IP:-未知}" "${DNS_IPS:-未查到}"
if [[ -n "$PUBLIC_IP" && -n "$DNS_IPS" ]] && ! grep -Fxq "$PUBLIC_IP" <<<"$DNS_IPS"; then
  read -r -p "域名 IP 与公网 IP 不一致，仍继续？[y/N]: " CONFIRM
  [[ "$CONFIRM" =~ ^[Yy]$ ]] || die "已取消"
fi

log "开始安装官方 Hysteria2"
TMP_INSTALL="$(mktemp)"
trap 'rm -f "$TMP_INSTALL"' EXIT
curl -fsSL --retry 3 https://get.hy2.sh/ -o "$TMP_INSTALL"
bash "$TMP_INSTALL"

install -d -m 700 /etc/hysteria
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP=""
if [[ -f /etc/hysteria/config.yaml ]]; then
  BACKUP="/etc/hysteria/config.yaml.bak.${STAMP}"
  cp -a /etc/hysteria/config.yaml "$BACKUP"
  log "原配置备份: $BACKUP"
fi

if [[ "$CERT_MODE" == 2 ]]; then
  install -d -m 750 /etc/hysteria/certs
  install -m 644 "$CERT_PATH" /etc/hysteria/certs/fullchain.pem
  install -m 600 "$KEY_PATH" /etc/hysteria/certs/privkey.pem
  # Official service generally runs as hysteria; allow it to read a copy of the key.
  if id hysteria >/dev/null 2>&1; then
    chown root:hysteria /etc/hysteria/certs /etc/hysteria/certs/privkey.pem
    chmod 750 /etc/hysteria/certs
    chmod 640 /etc/hysteria/certs/privkey.pem
  else
    die "服务用户 hysteria 不存在；检查官方安装结果"
  fi
fi

if [[ "$CERT_MODE" == 1 ]]; then
  cat > /etc/hysteria/config.yaml <<EOF
listen: :443
acme:
  domains:
    - "$DOMAIN"
  email: "$EMAIL"
  type: http
auth:
  type: password
  password: "$AUTH_PASS"
obfs:
  type: salamander
  salamander:
    password: "$OBFS_PASS"
EOF
else
  cat > /etc/hysteria/config.yaml <<EOF
listen: :443
tls:
  cert: /etc/hysteria/certs/fullchain.pem
  key: /etc/hysteria/certs/privkey.pem
  sniGuard: strict
auth:
  type: password
  password: "$AUTH_PASS"
obfs:
  type: salamander
  salamander:
    password: "$OBFS_PASS"
EOF
fi
chmod 600 /etc/hysteria/config.yaml

# Persist locally for copying to the client; never upload secrets to GitHub.
SECRETS_FILE="/root/hy2-client-${STAMP}.txt"
cat > "$SECRETS_FILE" <<EOF
Type: Hysteria2
Address: $DOMAIN
Port: 443
TLS: on
SNI: $DOMAIN
Allow Insecure: off
Password: $AUTH_PASS
Obfuscation: Salamander
Obfuscation Password: $OBFS_PASS
EOF
chmod 600 "$SECRETS_FILE"

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
  ufw allow 443/udp
  if [[ "$CERT_MODE" == 1 ]]; then ufw allow 80/tcp; fi
fi

log "启动服务"
systemctl enable hysteria-server.service >/dev/null
if ! systemctl restart hysteria-server.service; then
  log "启动失败；检查日志："
  journalctl -u hysteria-server.service -n 50 --no-pager || true
  if [[ -n "$BACKUP" ]]; then
    cp -a "$BACKUP" /etc/hysteria/config.yaml
    systemctl restart hysteria-server.service || true
    log "已尝试恢复原配置"
  fi
  die "服务启动失败"
fi
sleep 3
if ! systemctl is-active --quiet hysteria-server.service; then
  journalctl -u hysteria-server.service -n 50 --no-pager || true
  die "服务退出；原配置备份：${BACKUP:-无}"
fi

printf '\n====== HY2 安装完成 ======\n'
cat "$SECRETS_FILE"
printf '凭据文件: %s（仅 root 可读）\n' "$SECRETS_FILE"
printf '备份文件: %s\n' "${BACKUP:-无}"
printf '服务状态: '; systemctl is-active hysteria-server.service
printf '\n请在云安全组放行 UDP 443'
[[ "$CERT_MODE" == 1 ]] && printf ' 和 TCP 80（用于签发/续签证书）'
printf '。本脚本不会修改云安全组。\n'
printf '提示：服务运行不代表外网已连通；请使用客户端验证。\n'
