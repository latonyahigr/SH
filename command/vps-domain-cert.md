# VPS 域名证书交互申请脚本

Debian 12 及以上，以 root 执行。使用 Certbot + Let's Encrypt，手动添加 DNS TXT 验证。

## 一键执行

```bash
bash <(curl -fsSL "https://raw.githubusercontent.com/latonyahigr/SH/main/command/vps-domain-cert.sh?t=$(date +%s)")
```

如果没有 curl，先执行：

```bash
apt-get update
apt-get install -y curl ca-certificates
```

也可以先下载，检查成功后运行，避免下载失败被误认为执行成功：

```bash
curl -fSL --retry 3 "https://raw.githubusercontent.com/latonyahigr/SH/main/command/vps-domain-cert.sh?t=$(date +%s)" -o /root/vps-domain-cert.sh && bash /root/vps-domain-cert.sh
```

## 交互输入

| 输入项 | 说明 |
|---|---|
| 证书域名 `CERT_DOMAIN` | 完整域名，如 `dns.example.com`；不要带协议、端口、路径；不支持 IP 或通配符 |
| 联系邮箱 `CERT_EMAIL` | 你的有效邮箱，用于 ACME 账户注册 |
| 继续确认 | 输入 `y` 开始安装缺失依赖并申请 |
| Certbot 提示 | 按提示选择是否同意 Let's Encrypt 服务条款等 |
| 显示证书和私钥 | 默认不显示；需要复制到 CDN 时输入 `y`，不要把私钥发给他人 |

不需要 API 密钥。默认使用 Let's Encrypt 正式环境、RSA 2048 位密钥。

## DNS 验证

1. 看到 Certbot 的 TXT 提示时，先不要按回车。
2. 在域名当前的 DNS 平台添加本次要求的 TXT；保留现有 A、AAAA、CNAME。
3. 例如 `dns.example.com` 在 `example.com` 解析区填写主机记录 `_acme-challenge.dns`，值填写 Certbot 本次给出的字符串。如果平台要求完整名称，填写 `_acme-challenge.dns.example.com`。
4. 在另一个终端执行脚本给出的 `dig` 命令，确认结果包含本次值，等待 DNS 传播后回来按回车。
5. 签发成功后可以删除本次 TXT。

无需将域名解析到申请用的 VPS，不用开放该 VPS 的 80/443 端口或停止网站；VPS 需能访问软件源和 ACME 服务。

## 证书与部署

脚本成功后显示实际路径及有效期，默认保存为：

| 文件 | 用途 |
|---|---|
| `/etc/letsencrypt/live/你的域名/fullchain.pem` | 完整证书链，填写 CDN 的“证书／公钥” |
| `/etc/letsencrypt/live/你的域名/privkey.pem` | 对应私钥，填写“私钥” |

阿里云 DCDN：域名管理 → 目标域名 → HTTPS 配置 → HTTPS 证书 → 自定义上传。

复制全部内容，包含 BEGIN、END 以及完整证书链中的所有证书段。脚本只申请证书，不会自动修改 Nginx、上传 CDN 或重载网站。

## 续期与失败处理

- **手动 DNS 验证不会自动续期。**到期前重新执行脚本，输入相同域名和邮箱，按 Certbot 提示续期，需要验证时添加新的 TXT 值。
- 如果证书尚未到续期时间，可保留现有证书，不要反复强制签发。
- 续期后要重新上传证书和私钥到 CDN；本地更新不会自动同步。
- 验证失败检查 TXT 名称、值和生效情况；同时检查 CAA、网络及签发限制。
- 日志：`/var/log/letsencrypt/letsencrypt.log`。中途失败后修正原因，再运行脚本。

参考：[Certbot 手动 DNS 验证](https://eff-certbot.readthedocs.io/en/stable/using.html#manual)。
