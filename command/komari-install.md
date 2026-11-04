# Komari：Debian 12 / 13 + Docker + 宝塔反代

项目系统兼容要求：后续涉及系统的脚本与部署方案必须同时兼容 Debian 12 和 Debian 13。

域名：`jiankong.845788.xyz`。面板本机端口：7070。

## 1. 面板服务器执行

需要已有 Docker。脚本只用于 Debian 12 / 13，新装 Komari。

```bash
curl -fL --retry 3 -H 'Cache-Control: no-cache' "https://raw.githubusercontent.com/latonyahigr/SH/main/command/komari-install.sh?t=$(date +%s)" -o /root/komari-install.sh && bash /root/komari-install.sh panel
```

- 支持映射到主机 7070 的 Beszel hub 容器，以及直接监听 7070 的独立 systemd Beszel 服务。宿主机进程必须核对可执行文件、所属服务和 MainPID；无法确认或存在自动激活源时退出。
- 先拉取 `ghcr.io/komari-monitor/komari:1.6.1`，再停止 Beszel。
- Komari 使用非 root 容器用户，只发布 `127.0.0.1:7070`。
- HTTP 检查通过后移除原 Beszel 容器；宿主机服务则停止并禁用开机启动，保留程序和数据。不删除原卷、数据目录和 Beszel Agent。
- 启动检查失败会尝试恢复原 Beszel；原配置记录保存在 `/opt/komari/beszel-backup`，不是独立的数据备份。
- 新数据 `/opt/komari/data`；不覆盖已有 Komari 数据或同名容器。如果此前只因端口检查失败而留下检查记录，会把旧目录完整改名为 `/opt/komari-failed-时间-PID` 后重新部署。存在其他文件时退出。
- 不修改宝塔、其他容器、防火墙和 SSH。不要重新执行旧 Beszel Compose，否则可能再次占用端口。

## 2. 宝塔设置

先将域名解析到面板服务器 IP。宝塔创建 PHP 项目下的纯静态网站，绑定 `jiankong.845788.xyz`；已有该域名网站则编辑原站点。

反向代理参数：

| 项目 | 值 |
|---|---|
| 代理目录 | `/` |
| 目标 URL | `http://127.0.0.1:7070` |
| 发送域名 | `$host` |
| 缓存 | 关闭 |
| WebSocket | 开启 |

如果界面没有 WebSocket 选项，在该反代的配置文件中用下面内容替换原有 `location /`，不要重复添加第二个 `location /`，也不要替换整个网站配置：

```nginx
location / {
    proxy_pass http://127.0.0.1:7070;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    proxy_buffering off;
    proxy_cache off;
}
```

申请 SSL，启用强制 HTTPS。只需公网 80/443；7070 不对公网开放。Cloudflare 如开启代理，SSL 使用 Full (strict)。不缓存接口或 WebSocket。

访问 https://jiankong.845788.xyz 完成初始化，设置独立强密码、开启双重验证；不启用无用的全局 API Key、主题和插件。

## 3. 节点安装

面板中为每台服务器新增节点，复制各自的节点 Token。不要执行面板默认生成的 Agent 安装命令。每台 Debian 12 / 13 节点执行：

```bash
curl -fL --retry 3 -H 'Cache-Control: no-cache' "https://raw.githubusercontent.com/latonyahigr/SH/main/command/komari-install.sh?t=$(date +%s)" -o /root/komari-install.sh && bash /root/komari-install.sh agent
```

按提示粘贴 Token（不回显）。固定下载 Agent 1.5.11，校验官方发布资产 SHA256，使用无额外用户组的普通用户 `komari-monitor`，禁止提升权限，限制系统文件写入，启用 `--disable-web-ssh --disable-auto-update`。无效 HTTPS 证书会被拒绝。已有 Agent 服务/文件时退出，不覆盖。

**只安装面板不能禁用节点远程控制。每台节点都必须使用上述受限 Agent。**

检查：

```bash
systemctl show komari-monitor -p User -p Group -p ExecStart -p NoNewPrivileges
journalctl -u komari-monitor -n 50 --no-pager
```

先试一台：确认节点在线、指标正常，然后在面板尝试终端、无害命令 `whoami` 和文件操作，必须被拒绝；重启节点后再次验证，再批量安装。普通用户可能无法获取部分指标或进行 ICMP 探测，先检查原因，不直接赋予 root 权限。

Beszel Agent 需要在其所在服务器另行识别和卸载；本脚本不根据模糊名称批量删除服务。未来安全修复需手动评估、验证和分批升级。

## 常用命令

```bash
docker ps --filter name=komari
docker logs --tail 50 komari
curl -I http://127.0.0.1:7070/
systemctl status komari-monitor --no-pager
```

面板备份应定期独立保存。简单的一致性备份（在面板主机执行，会短暂停止监控面板）：

```bash
(
set -e
install -d -m 0700 /root/komari-backups
docker stop komari
trap 'docker start komari >/dev/null' EXIT
tar -C /opt/komari -czf "/root/komari-backups/data-$(date +%Y%m%d-%H%M%S).tar.gz" data
)
```

参考：官方 Komari Dockerfile、1.6.1 发布记录、Agent 1.5.11 源码及发布资产。脚本已做 Bash 语法检查及模拟 Docker、宿主机 systemd 替换、失败恢复和旧失败记录重试测试；模拟测试不替代目标机实际验收。
