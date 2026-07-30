#!/usr/bin/env bash

# 关闭 UFW
ufw --force disable 2>/dev/null || true

# 停止并禁用 firewalld
systemctl stop firewalld 2>/dev/null || true
systemctl disable firewalld 2>/dev/null || true

# 清空 IPv4 防火墙规则
iptables -P INPUT ACCEPT 2>/dev/null || true
iptables -P FORWARD ACCEPT 2>/dev/null || true
iptables -P OUTPUT ACCEPT 2>/dev/null || true
iptables -F 2>/dev/null || true

# 清空 IPv6 防火墙规则
ip6tables -P INPUT ACCEPT 2>/dev/null || true
ip6tables -P FORWARD ACCEPT 2>/dev/null || true
ip6tables -P OUTPUT ACCEPT 2>/dev/null || true
ip6tables -F 2>/dev/null || true

echo "✅ UFW、firewalld 和 iptables 防火墙规则已关闭"
