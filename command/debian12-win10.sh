#!/usr/bin/env bash
set -u

readonly INSTALL_URL="https://raw.githubusercontent.com/leitbogioro/Tools/master/Linux_reinstall/InstallNET.sh"
readonly INSTALL_SCRIPT="/root/InstallNET.sh"
readonly INSTALL_LOG="/root/InstallNET.log"

# 必须使用 root
if [[ "$(id -u)" -ne 0 ]]; then
    echo "❌ 请使用 root 用户执行"
    exit 1
fi

echo "▶ 更新软件源并安装依赖……"
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y wget ca-certificates

echo "▶ 下载 Windows 重装脚本……"
wget --no-check-certificate \
    --timeout=30 \
    --tries=3 \
    -O "$INSTALL_SCRIPT" \
    "$INSTALL_URL"

if [[ ! -s "$INSTALL_SCRIPT" ]]; then
    echo "❌ InstallNET.sh 下载失败或文件为空"
    exit 1
fi

chmod 700 "$INSTALL_SCRIPT"

echo "▶ 配置 Windows 10 网络重装……"
echo "⚠️ 此操作将清除当前 VPS 系统和磁盘数据"

# 原脚本成功时也会返回 exit 1，因此不能直接依赖退出状态
bash "$INSTALL_SCRIPT" -windows 10 2>&1 | tee "$INSTALL_LOG"

# 删除颜色代码后检查成功标志
CLEAN_LOG="$(sed 's/\x1B\[[0-9;]*[mK]//g' "$INSTALL_LOG")"

if grep -qE '\[Finish\].*reboot.*installation' <<< "$CLEAN_LOG"; then
    echo "✅ 重装环境配置成功，5 秒后自动重启"
    sync
    sleep 5
    /sbin/reboot
else
    echo "❌ 没有检测到配置成功标志，为防止误重启，操作已停止"
    echo "请检查日志：$INSTALL_LOG"
    exit 1
fi
