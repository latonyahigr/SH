#!/usr/bin/env bash
# ZeroSSL REST API IP HTTPS 一键部署（Debian 12+ / 宝塔 Nginx）
# 变量可在此修改；留空时启动后会交互询问。
DEFAULT_IP=""                         # 公网 IPv4；留空自动检测并让用户确认
WEBROOT="/www/wwwroot/ssl.com"        # 网站根目录（仅用于 HTTP 验证）
CERT_BASE="/etc/zerossl/ip"           # 私钥与证书存储目录（网站根目录之外）
VALIDITY_DAYS="90"                    # ZeroSSL 证书有效期
POLL_ATTEMPTS=18                      # 验证状态查询次数
POLL_SECONDS=10                       # 每次查询间隔（秒）
NGINX_BIN="/www/server/nginx/sbin/nginx"
VHOST_DIR="/www/server/panel/vhost/nginx"

set -Eeuo pipefail
umask 077
die(){ echo "[错误] $*" >&2; exit 1; }
info(){ echo "[信息] $*"; }
trap 'echo "[失败] 第 $LINENO 行。证书订单/文件保留，可检查日志后处理；不会自动重复下单。" >&2' ERR

[[ ${EUID} -eq 0 ]] || die "请使用 root 执行"
[[ -r /etc/os-release ]] || die "无法识别系统"
. /etc/os-release
[[ "${ID:-}" == "debian" && "${VERSION_ID%%.*}" =~ ^[0-9]+$ && "${VERSION_ID%%.*}" -ge 12 ]] || die "仅支持 Debian 12 或更高版本"
[[ -x "$NGINX_BIN" && -d "$VHOST_DIR" ]] || die "没有检测到宝塔 Nginx，请先安装宝塔及 Nginx"
command -v apt-get >/dev/null || die "缺少 apt-get"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl jq openssl ca-certificates >/dev/null

IP="$DEFAULT_IP"
if [[ -z "$IP" ]]; then
  DETECTED_IP="$(curl --noproxy '*' -4fsS --connect-timeout 5 --max-time 12 https://api.ipify.org || true)"
  read -r -p "公网 IPv4 [${DETECTED_IP:-手动输入}]: " IP </dev/tty
  IP="${IP:-$DETECTED_IP}"
fi
[[ "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "IP 格式错误"
IFS=. read -r a b c d <<<"$IP"
for n in "$a" "$b" "$c" "$d"; do ((10#$n <= 255)) || die "IP 格式错误"; done
[[ "$IP" != 0.* && "$IP" != 127.* && "$IP" != 255.* ]] || die "请使用公网 IPv4"

CERT_DIR="$CERT_BASE/$IP"
CONF="$VHOST_DIR/zz-zerossl-ip-${IP//./-}.conf"
[[ ! -e "$CONF" ]] || die "脚本管理的站点配置已存在：$CONF。请勿重复执行覆盖"
# 检查其他宝塔网站是否已经绑定该 IP；不修改其他业务。
if grep -El "server_name[[:space:]][^;]*$IP([[:space:];]|$)" "$VHOST_DIR"/*.conf 2>/dev/null | grep -q .; then
  die "已有宝塔网站声明此 IP；为防止冲突，请先处理现有虚拟主机后再执行"
fi
if [[ -e "$CERT_DIR/private.key" || -e "$CERT_DIR/order.json" ]]; then
  die "发现已有私钥或订单：$CERT_DIR；禁止重复申请或覆盖"
fi
[[ "$WEBROOT" == /* && "$WEBROOT" != "/" && "$WEBROOT" != *$'\n'* ]] || die "WEBROOT 无效"
[[ "$CERT_BASE" != "$WEBROOT"* ]] || die "证书私钥不得位于网站根目录"
mkdir -p "$CERT_DIR" "$WEBROOT/.well-known/pki-validation"
chmod 700 "$CERT_DIR"
chmod 755 "$WEBROOT" "$WEBROOT/.well-known" "$WEBROOT/.well-known/pki-validation"

echo
info "目标 IP：$IP"
info "验证目录：$WEBROOT/.well-known/pki-validation"
info "证书目录：$CERT_DIR"
info "将新增独立 IP 站点配置：$CONF"
read -r -p "确认继续？输入 YES: " CONFIRM </dev/tty
[[ "$CONFIRM" == "YES" ]] || die "用户取消"
read -r -s -p "输入 ZeroSSL API Key（输入不显示）: " API_KEY </dev/tty
echo
[[ "$API_KEY" =~ ^[a-zA-Z0-9]{16,128}$ ]] || die "API Key 格式不正确"
# 避免在命令行参数中直接带出 API Key；curl 从临时 fd 读取 URL。
api_url(){ printf 'url = "https://api.zerossl.com%s?access_key=%s"\n' "$1" "$API_KEY"; }

info "创建仅用于 IP 验证的 HTTP 站点..."
cat > "$CONF" <<EOF
# Managed by zerossl-ip-install.sh. Do not combine with another IP virtual host.
server {
    listen 80;
    server_name $IP;
    root $WEBROOT;
    location ~ ^/\\.well-known/pki-validation/[A-Za-z0-9_-]+\\.txt$ {
        default_type text/plain;
        try_files \\$uri =404;
    }
    location / { return 404; }
}
EOF
if ! "$NGINX_BIN" -t; then rm -f "$CONF"; die "Nginx 配置检查失败，已撤销新站点"; fi
"$NGINX_BIN" -s reload
printf 'READY\n' > "$WEBROOT/.well-known/pki-validation/test.txt"
HTTP_TEST="$(curl --noproxy '*' -fsS --max-time 15 "http://$IP/.well-known/pki-validation/test.txt" || true)"
[[ "$HTTP_TEST" == "READY" ]] || die "公网 HTTP 验证失败。请检查安全组 TCP 80、Nginx 虚拟主机和公网 IP"
rm -f "$WEBROOT/.well-known/pki-validation/test.txt"

info "生成 IP SAN 私钥与 CSR..."
openssl req -new -newkey rsa:2048 -nodes -keyout "$CERT_DIR/private.key" \
  -out "$CERT_DIR/request.csr" -subj "/CN=$IP" -addext "subjectAltName=IP:$IP" >/dev/null 2>&1
chmod 600 "$CERT_DIR/private.key"
info "向 ZeroSSL 创建 90 天证书订单..."
curl -fsS --config <(api_url "/certificates") -X POST \
  --data-urlencode "certificate_domains=$IP" \
  --data-urlencode "certificate_validity_days=$VALIDITY_DAYS" \
  --data-urlencode "certificate_csr@$CERT_DIR/request.csr" \
  --data-urlencode "strict_domains=1" -o "$CERT_DIR/order.json" || die "创建订单 HTTP 请求失败"
CERT_ID="$(jq -r '.id // empty' "$CERT_DIR/order.json")"
[[ -n "$CERT_ID" ]] || { jq '{success,error}' "$CERT_DIR/order.json"; die "证书订单创建失败"; }
info "订单 ID：$CERT_ID"

VALIDATION_URL="$(jq -r --arg ip "$IP" '.validation.other_methods[$ip].file_validation_url_http // empty' "$CERT_DIR/order.json")"
case "$VALIDATION_URL" in
  "http://$IP/.well-known/pki-validation/"*.txt) ;;
  *) die "ZeroSSL 返回的验证 URL 异常：$VALIDATION_URL" ;;
esac
FILE="$WEBROOT/.well-known/pki-validation/${VALIDATION_URL##*/}"
jq -er --arg ip "$IP" '.validation.other_methods[$ip].file_validation_content | join("\n")' "$CERT_DIR/order.json" > "$FILE"
chmod 644 "$FILE"
curl --noproxy '*' -fsS --max-time 15 "$VALIDATION_URL" -o "$CERT_DIR/public-validation.txt" || die "公网验证文件无法访问"
cmp -s "$FILE" "$CERT_DIR/public-validation.txt" || die "公网验证内容与 ZeroSSL 不一致"

info "提交 HTTP 验证..."
curl -fsS --config <(api_url "/certificates/$CERT_ID/challenges") -X POST \
  --data-urlencode "validation_method=HTTP_CSR_HASH" \
  -o "$CERT_DIR/verify.json" || die "提交验证请求失败"
if [[ "$(jq -r '.success // true' "$CERT_DIR/verify.json")" == "false" ]]; then
  jq '.error' "$CERT_DIR/verify.json"; die "ZeroSSL 拒绝验证"
fi

STATUS=""
for ((i=1; i<=POLL_ATTEMPTS; i++)); do
  curl -fsS --config <(api_url "/certificates/$CERT_ID") \
    -o "$CERT_DIR/status.json" || die "查询签发状态失败"
  STATUS="$(jq -r '.status // empty' "$CERT_DIR/status.json")"
  info "签发状态（$i/$POLL_ATTEMPTS）：$STATUS"
  [[ "$STATUS" == "issued" ]] && break
  [[ "$STATUS" == "cancelled" || "$STATUS" == "expired" || "$STATUS" == "revoked" ]] && die "订单状态异常：$STATUS"
  sleep "$POLL_SECONDS"
done
[[ "$STATUS" == "issued" ]] || die "尚未签发。订单已保留在 $CERT_DIR，请稍后检查 ZeroSSL 状态"

info "下载证书..."
curl -fsS --config <(api_url "/certificates/$CERT_ID/download/json") \
  -o "$CERT_DIR/download.json" || die "下载证书失败"
jq -e '."certificate.crt" and ."ca_bundle.crt"' "$CERT_DIR/download.json" >/dev/null || die "证书下载内容错误"
jq -r '."certificate.crt"' "$CERT_DIR/download.json" > "$CERT_DIR/certificate.crt"
jq -r '."ca_bundle.crt"' "$CERT_DIR/download.json" > "$CERT_DIR/ca_bundle.crt"
cat "$CERT_DIR/certificate.crt" "$CERT_DIR/ca_bundle.crt" > "$CERT_DIR/fullchain.pem"
chmod 600 "$CERT_DIR/private.key"
chmod 644 "$CERT_DIR/fullchain.pem" "$CERT_DIR/certificate.crt" "$CERT_DIR/ca_bundle.crt"
openssl x509 -in "$CERT_DIR/certificate.crt" -noout -checkip "$IP" | grep -q 'does match certificate' || die "证书 SAN 未包含目标 IP"
CERT_PUB="$(openssl x509 -in "$CERT_DIR/certificate.crt" -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256)"
KEY_PUB="$(openssl pkey -in "$CERT_DIR/private.key" -pubout -outform DER | openssl dgst -sha256)"
[[ "$CERT_PUB" == "$KEY_PUB" ]] || die "私钥不匹配"

info "启用 443 HTTPS..."
cp -p "$CONF" "$CERT_DIR/http-vhost.conf"
cat > "$CONF" <<EOF
# Managed by zerossl-ip-install.sh. HTTP challenge and HTTPS IP site.
server {
    listen 80;
    server_name $IP;
    root $WEBROOT;
    location ~ ^/\\.well-known/pki-validation/[A-Za-z0-9_-]+\\.txt$ {
        default_type text/plain;
        try_files \\$uri =404;
    }
    location / { return 404; }
}
server {
    listen 443 ssl;
    server_name $IP;
    root $WEBROOT;
    ssl_certificate $CERT_DIR/fullchain.pem;
    ssl_certificate_key $CERT_DIR/private.key;
    location / { try_files \\$uri \\$uri/ =404; }
}
EOF
if ! "$NGINX_BIN" -t; then
  cp -p "$CERT_DIR/http-vhost.conf" "$CONF"
  die "HTTPS 配置检查失败，已恢复 HTTP 配置"
fi
"$NGINX_BIN" -s reload
TLS_RESULT="$(curl --noproxy '*' -sS -o /dev/null -w '%{ssl_verify_result}' --max-time 15 "https://$IP/" || true)"
[[ "$TLS_RESULT" == "0" ]] || die "HTTPS 已配置但证书校验未通过，检查公网 TCP 443、证书链和默认站点"

info "成功：https://$IP/"
openssl x509 -in "$CERT_DIR/certificate.crt" -noout -dates -ext subjectAltName
info "证书目录：$CERT_DIR"
info "Nginx 配置：$CONF"
info "本脚本只负责首次申请，不包含自动续期。请在证书到期前重新签发。"
