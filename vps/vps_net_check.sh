#!/usr/bin/env bash
set -Eeuo pipefail

LOG_DIR="/root/vps-net-check"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/report-$(date +%F-%H%M%S).log"

exec > >(tee -a "$LOG_FILE") 2>&1

echo "=============================="
echo " VPS Network Check for Debian 12"
echo " Time: $(date)"
echo " Hostname: $(hostname)"
echo " Kernel: $(uname -r)"
echo "=============================="
echo

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "请用 root 运行。"
    exit 1
  fi
}

install_deps() {
  echo "[1/6] 安装依赖..."
  apt-get update -y
  apt-get install -y curl wget jq ca-certificates gnupg lsb-release mtr-tiny iproute2 dnsutils bc coreutils procps
  echo
}

install_speedtest() {
  if command -v speedtest >/dev/null 2>&1; then
    echo "Ookla speedtest 已安装：$(command -v speedtest)"
    return
  fi

  echo "[2/6] 安装 Ookla Speedtest CLI..."
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://packagecloud.io/ookla/speedtest-cli/gpgkey | gpg --dearmor -o /etc/apt/keyrings/ookla_speedtest.gpg
  echo "deb [signed-by=/etc/apt/keyrings/ookla_speedtest.gpg] https://packagecloud.io/ookla/speedtest-cli/debian/ bookworm main" \
    > /etc/apt/sources.list.d/ookla_speedtest.list
  apt-get update -y
  apt-get install -y speedtest
  echo
}

install_librespeed() {
  if command -v librespeed-cli >/dev/null 2>&1; then
    echo "librespeed-cli 已安装：$(command -v librespeed-cli)"
    return
  fi

  echo "[3/6] 安装 LibreSpeed CLI..."
  ARCH="$(dpkg --print-architecture)"
  TMP_DEB="/tmp/librespeed-cli.deb"

  case "$ARCH" in
    amd64)
      URL="https://github.com/librespeed/speedtest-cli/releases/latest/download/librespeed-cli_$(uname -m)_deb.deb"
      ;;
    arm64)
      URL="https://github.com/librespeed/speedtest-cli/releases/latest/download/librespeed-cli_arm64.deb"
      ;;
    *)
      echo "未识别架构 $ARCH，跳过 librespeed-cli 安装。"
      return
      ;;
  esac

  if curl -fsL "$URL" -o "$TMP_DEB"; then
    apt-get install -y "$TMP_DEB" || true
    rm -f "$TMP_DEB"
  else
    echo "LibreSpeed CLI 下载失败，跳过。"
  fi
  echo
}

show_system_info() {
  echo "[4/6] 系统与网络信息"
  echo "---- IP / Route ----"
  ip addr show
  echo
  ip route
  echo
  echo "---- DNS ----"
  cat /etc/resolv.conf || true
  echo
  echo "---- Public IP ----"
  curl -4 -s https://api.ipify.org && echo
  curl -6 -s https://api64.ipify.org || true
  echo
  echo
}

run_mtr_tests() {
  echo "[5/6] 基础链路质量测试"
  TARGETS=("1.1.1.1" "8.8.8.8" "223.5.5.5")

  for t in "${TARGETS[@]}"; do
    echo "---- mtr to $t ----"
    mtr -rwzc 20 "$t" || true
    echo
  done
}

run_speedtests() {
  echo "[6/6] 吞吐测试"
  echo

  if command -v speedtest >/dev/null 2>&1; then
    echo "---- Ookla Speedtest ----"
    speedtest --accept-license --accept-gdpr -f json | jq .
    echo
  else
    echo "未找到 speedtest，跳过。"
  fi

  if command -v librespeed-cli >/dev/null 2>&1; then
    echo "---- LibreSpeed CLI ----"
    librespeed-cli --json || true
    echo
  else
    echo "未找到 librespeed-cli，跳过。"
  fi

  echo "---- 单线程 HTTP 下载测试 ----"
  echo "说明：这部分更容易暴露单线程限速。"
  TEST_URLS=(
    "http://speedtest.tele2.net/100MB.zip"
    "http://ipv4.download.thinkbroadband.com/100MB.zip"
  )

  for url in "${TEST_URLS[@]}"; do
    echo "Testing: $url"
    curl -L -o /dev/null -4 --connect-timeout 10 --max-time 60 -w \
'namelookup=%{time_namelookup}s connect=%{time_connect}s starttransfer=%{time_starttransfer}s total=%{time_total}s speed=%{speed_download}B/s\n' \
      "$url" || true
    echo
  done

  echo "---- 持续下载测试（120秒） ----"
  echo "说明：短测速正常但长时间被整形，这里更容易看出来。"
  timeout 120s bash -c 'curl -L http://speedtest.tele2.net/1GB.zip -o /dev/null -4 -w "avg_speed=%{speed_download}B/s total=%{time_total}s\n"' || true
  echo
}

summary_hint() {
  echo "=============================="
  echo "初步判断方法："
  echo "1. speedtest 很高，但单线程 curl 很差："
  echo "   可能是单线程限速、跨境路由差、运营商 QoS，或者测速节点过于近。"
  echo
  echo "2. 短时间快，120秒持续下载明显掉速："
  echo "   很像整形、突发带宽后限速，或者共享口拥塞。"
  echo
  echo "3. mtr 显示高丢包/高抖动："
  echo "   说明链路质量有问题，不是纯带宽问题。"
  echo
  echo "4. 不同测速节点差异极大："
  echo "   说明不是 VPS 总带宽稳定，而是路由/对端/地区方向明显不均衡。"
  echo
  echo "5. 上传明显低于下载，或者反过来："
  echo "   可能存在方向性限速。"
  echo
  echo "日志文件： $LOG_FILE"
  echo "=============================="
}

main() {
  require_root
  install_deps
  install_speedtest
  install_librespeed
  show_system_info
  run_mtr_tests
  run_speedtests
  summary_hint
}

main "$@"
