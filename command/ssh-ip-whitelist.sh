#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# SSH IP whitelist
# Supports: Debian 10/11/12/13, Ubuntu 22.04/24.04
# ============================================================

SSH_PORT="${SSH_PORT:-57777}"
CHAIN_NAME="SSH_WHITELIST"

ALLOWED_IPV4=(
    "159.195.32.77"
    "178.104.148.114"
)

ALLOWED_IPV6=(
    "2a01:4f8:1c18:fd00::1"
    "2a0a:4cc0:c1:60d8:2444:ceff:fe11:f6f0"
)

export DEBIAN_FRONTEND=noninteractive

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
    printf '错误：%s\n' "$*" >&2
    exit 1
}

if [[ "${EUID}" -ne 0 ]]; then
    die "请使用 root 用户运行，或者使用 sudo bash 执行。"
fi

if ! [[ "${SSH_PORT}" =~ ^[0-9]+$ ]] ||
   (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
    die "SSH端口无效：${SSH_PORT}"
fi

# 检查SSH配置语法
if command -v sshd >/dev/null 2>&1; then
    sshd -t || die "SSH配置检测失败，已停止执行。"
fi

# 检查目标端口是否正在监听
if command -v ss >/dev/null 2>&1; then
    if ! ss -H -lnt | awk '{print $4}' |
        grep -Eq "(^|:|\])${SSH_PORT}$"; then
        die "没有发现端口 ${SSH_PORT} 正在监听。请确认SSH实际端口。"
    fi
fi

# 防止当前SSH连接的来源IP不在白名单中
if [[ -n "${SSH_CONNECTION:-}" ]]; then
    CURRENT_IP="${SSH_CONNECTION%% *}"
    CURRENT_ALLOWED="false"

    for IP in "${ALLOWED_IPV4[@]}" "${ALLOWED_IPV6[@]}"; do
        if [[ "${CURRENT_IP}" == "${IP}" ]]; then
            CURRENT_ALLOWED="true"
            break
        fi
    done

    if [[ "${CURRENT_ALLOWED}" != "true" ]]; then
        die "当前登录IP ${CURRENT_IP} 不在白名单中，为防止锁死，已停止执行。"
    fi

    log "当前登录IP已通过白名单检查：${CURRENT_IP}"
fi

log "安装iptables持久化组件……"
apt-get update
apt-get install -y iptables iptables-persistent netfilter-persistent

install -d -m 700 /etc/iptables

# 备份现有持久化规则
BACKUP_TIME="$(date '+%Y%m%d-%H%M%S')"

if [[ -f /etc/iptables/rules.v4 ]]; then
    cp -a /etc/iptables/rules.v4 \
        "/etc/iptables/rules.v4.backup-${BACKUP_TIME}"
fi

if [[ -f /etc/iptables/rules.v6 ]]; then
    cp -a /etc/iptables/rules.v6 \
        "/etc/iptables/rules.v6.backup-${BACKUP_TIME}"
fi

log "配置IPv4白名单……"

iptables -w -N "${CHAIN_NAME}" 2>/dev/null || true
iptables -w -F "${CHAIN_NAME}"

# 删除可能存在的重复跳转规则
while iptables -w -C INPUT \
    -p tcp --dport "${SSH_PORT}" \
    -j "${CHAIN_NAME}" 2>/dev/null; do
    iptables -w -D INPUT \
        -p tcp --dport "${SSH_PORT}" \
        -j "${CHAIN_NAME}"
done

# 放在INPUT链最前面
iptables -w -I INPUT 1 \
    -p tcp --dport "${SSH_PORT}" \
    -j "${CHAIN_NAME}"

for IP in "${ALLOWED_IPV4[@]}"; do
    iptables -w -A "${CHAIN_NAME}" \
        -s "${IP}/32" \
        -m comment --comment "Allowed SSH IPv4" \
        -j ACCEPT
done

iptables -w -A "${CHAIN_NAME}" \
    -m comment --comment "Drop unauthorized SSH IPv4" \
    -j DROP

# 仅在系统启用IPv6时配置IPv6规则
if [[ -s /proc/net/if_inet6 ]]; then
    log "配置IPv6白名单……"

    ip6tables -w -N "${CHAIN_NAME}" 2>/dev/null || true
    ip6tables -w -F "${CHAIN_NAME}"

    while ip6tables -w -C INPUT \
        -p tcp --dport "${SSH_PORT}" \
        -j "${CHAIN_NAME}" 2>/dev/null; do
        ip6tables -w -D INPUT \
            -p tcp --dport "${SSH_PORT}" \
            -j "${CHAIN_NAME}"
    done

    ip6tables -w -I INPUT 1 \
        -p tcp --dport "${SSH_PORT}" \
        -j "${CHAIN_NAME}"

    for IP in "${ALLOWED_IPV6[@]}"; do
        ip6tables -w -A "${CHAIN_NAME}" \
            -s "${IP}/128" \
            -m comment --comment "Allowed SSH IPv6" \
            -j ACCEPT
    done

    ip6tables -w -A "${CHAIN_NAME}" \
        -m comment --comment "Drop unauthorized SSH IPv6" \
        -j DROP
else
    log "系统未启用IPv6，跳过IPv6规则。"
fi

log "保存防火墙规则……"

iptables-save > /etc/iptables/rules.v4

if [[ -s /proc/net/if_inet6 ]]; then
    ip6tables-save > /etc/iptables/rules.v6
fi

systemctl enable netfilter-persistent
systemctl restart netfilter-persistent

log "验证IPv4规则："
iptables -w -L "${CHAIN_NAME}" -n -v --line-numbers

if [[ -s /proc/net/if_inet6 ]]; then
    log "验证IPv6规则："
    ip6tables -w -L "${CHAIN_NAME}" -n -v --line-numbers
fi

log "配置完成：SSH端口 ${SSH_PORT} 仅允许白名单IP访问。"
log "请保留当前SSH窗口，并使用另一网络进行登录测试。"
