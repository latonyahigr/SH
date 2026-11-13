#!/usr/bin/env bash
# Debian 12+：交互申请 Let's Encrypt 域名证书（手动 DNS TXT 验证）。
# 运行时输入 CERT_DOMAIN（完整域名）和 CERT_EMAIL（联系邮箱）。
# 不支持 IP / 通配符；不修改网站、现有 DNS 解析或防火墙。
# 手动验证不能自动续期，更新证书后需重新上传 CDN。
set -Eeuo pipefail
umask 077

readonly ACME_SERVER='https://acme-v02.api.letsencrypt.org/directory'
readonly KEY_BITS=2048
CERT_DOMAIN=''
CERT_EMAIL=''

die() { printf '错误：%s\n' "$*" >&2; exit 1; }

valid_domain() {
    local domain="$1" label
    local -a labels
    [[ ${#domain} -le 253 && "$domain" == *.* && "$domain" != *..* ]] || return 1
    [[ "$domain" =~ ^[a-z0-9.-]+$ && "$domain" != .* && "$domain" != *. ]] || return 1
    [[ ! "$domain" =~ ^[0-9.]+$ ]] || return 1
    IFS='.' read -r -a labels <<< "$domain"
    for label in "${labels[@]}"; do
        [[ ${#label} -ge 1 && ${#label} -le 63 ]] || return 1
        [[ "$label" != -* && "$label" != *- ]] || return 1
    done
}

valid_email() {
    [[ "$1" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ && "$1" != -* ]]
}

ask() {
    printf '%s' "$1" >&3
    IFS= read -r REPLY <&3 || die '输入已中断。'
}

main() {
    [[ "$EUID" -eq 0 ]] || die '请用 root 执行，或使用 sudo bash 脚本路径。'
    [[ -r /etc/os-release ]] || die '无法识别操作系统。'
    local ID VERSION_ID
    . /etc/os-release
    [[ "${ID:-}" == debian && "${VERSION_ID:-}" =~ ^[0-9]+$ ]] || die '仅支持 Debian 12 及以上。'
    (( VERSION_ID >= 12 )) || die '仅支持 Debian 12 及以上。'
    if ! { exec 3<>/dev/tty; } 2>/dev/null; then
        die '需要交互终端，请登录 SSH 后执行，不要放入计划任务。'
    fi
    trap 'printf "\n执行失败，请查看上方报错；Certbot 日志：/var/log/letsencrypt/letsencrypt.log\n" >&2' ERR
    trap 'printf "\n已中止。\n" >&2; exit 130' INT

    printf '\n=== VPS 域名证书申请（手动 DNS 验证）===\n'
    printf '输入完整域名，不带 https://、端口或路径；中文域名请先转为 Punycode。\n'
    while :; do
        ask '证书域名（如 dns.example.com）：'
        CERT_DOMAIN="${REPLY,,}"
        valid_domain "$CERT_DOMAIN" && break
        printf '域名格式无效；不支持 IP 或通配符。\n' >&3
    done
    while :; do
        ask '联系邮箱：'
        CERT_EMAIL="$REPLY"
        valid_email "$CERT_EMAIL" && break
        printf '邮箱格式无效，请重新输入。\n' >&3
    done

    printf '\n域名：%s\n邮箱：%s\n' "$CERT_DOMAIN" "$CERT_EMAIL"
    printf '将安装缺失依赖、注册或使用 ACME 账户并申请证书。\n'
    printf '验证时需手动添加 TXT；不会自动配置网站或同步 CDN。\n'
    ask '继续？[y/N]：'
    [[ "$REPLY" == y || "$REPLY" == Y ]] || { printf '已取消。\n'; return 0; }

    local -a missing=()
    command -v certbot >/dev/null 2>&1 || missing+=(certbot)
    command -v dig >/dev/null 2>&1 || missing+=(dnsutils)
    command -v openssl >/dev/null 2>&1 || missing+=(openssl)
    command -v flock >/dev/null 2>&1 || missing+=(util-linux)
    if (( ${#missing[@]} )); then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
    fi

    exec 9>/run/lock/vps-domain-cert.lock
    flock -n 9 || die '另一个本脚本正在运行，请等待结束。'

    printf '\n看到 Certbot 的 TXT 提示后：\n'
    printf '1. 在 DNS 平台新增其指定的 TXT 名称和本次验证值，保留原有解析。\n'
    printf '2. 在另一个终端执行：dig +short TXT _acme-challenge.%s @1.1.1.1\n' "$CERT_DOMAIN"
    printf '3. 确认包含本次验证值并等待传播，再回来按回车。\n'
    printf '例：dns.example.com 在 example.com 解析区的主机记录为 _acme-challenge.dns。\n'
    printf '服务条款由 Certbot 展示，请按提示自行选择是否同意。\n\n'

    # 明确连接终端，兼容 bash <(curl ...)；保留 Certbot 的交互确认与错误输出。
    if ! certbot certonly --manual --preferred-challenges dns \
        --server "$ACME_SERVER" --key-type rsa --rsa-key-size "$KEY_BITS" \
        --cert-name "$CERT_DOMAIN" --email "$CERT_EMAIL" -d "$CERT_DOMAIN" <&3 >&3 2>&3; then
        die 'Certbot 未成功完成；检查 DNS TXT、CAA、网络、签发限制及 /var/log/letsencrypt/letsencrypt.log 后重试。'
    fi

    local cert_dir="/etc/letsencrypt/live/$CERT_DOMAIN"
    [[ -s "$cert_dir/fullchain.pem" && -s "$cert_dir/privkey.pem" ]] || die '未找到完整证书链或私钥，请检查 Certbot 显示的保存路径。'
    printf '\n=== 当前证书 ===\n'
    openssl x509 -in "$cert_dir/fullchain.pem" -noout -subject -issuer -dates -ext subjectAltName
    printf '\n完整证书链：%s/fullchain.pem\n私钥：%s/privkey.pem\n' "$cert_dir" "$cert_dir"
    printf '\n阿里云 DCDN → 域名管理 → HTTPS 配置 → 自定义上传：\n'
    printf '证书（公钥）填写 fullchain.pem 全部内容；私钥填写 privkey.pem 全部内容。\n'
    printf '查看证书：cat %q/fullchain.pem\n' "$cert_dir"
    printf '查看私钥：cat %q/privkey.pem\n' "$cert_dir"
    printf '\n私钥仅供上传目标平台，不要公开或提交 GitHub。\n'
    ask '是否现在在终端显示完整证书和私钥？[y/N]：'
    if [[ "$REPLY" == y || "$REPLY" == Y ]]; then
        printf '\n=== 完整证书链（全部复制）===\n'
        cat "$cert_dir/fullchain.pem"
        printf '\n=== 私钥（全部复制，勿公开）===\n'
        cat "$cert_dir/privkey.pem"
    fi
    printf '\n手动 DNS 验证不会自动续期。到期前重新运行脚本，按提示续期并更新 TXT。\n'
    printf '若提示证书尚未到期，可保留现有证书；不要反复强制签发。\n'
    printf '续期后需重新上传证书和私钥到 CDN；成功验证后可删除本次 TXT。\n'
}

if [[ "${BASH_SOURCE[0]:-}" == "$0" ]]; then
    main "$@"
fi
