# FreePassword

自建密码库，零订阅费。**Vaultwarden + Cloudflare Tunnel + 每日加密备份**。

不用公网 IP、不开入站端口、不用折腾 Nginx 和证书，手机 / 电脑 / 浏览器插件全都能同步。客户端直接用官方的 Bitwarden App 和浏览器插件，登录时选「自托管」。

```
手机 / 浏览器 / 电脑
        │  HTTPS
        ▼
   Cloudflare（自动证书、隐藏真实 IP）
        │  Tunnel（服务器主动连出去）
        ▼
  cloudflared 容器 ──► Vaultwarden 容器
                        │
                        ▼
                     vw-data/ ──► 每日 AES-256 加密包 ──► iCloud / 任意目录
```

## 为什么是这四个东西

| 组件 | 解决的问题 | 取舍 |
|---|---|---|
| Vaultwarden | 兼容 Bitwarden 官方客户端，几十 MB 内存 | 非官方实现，别去官方渠道报 bug |
| Cloudflare Tunnel | 免公网 IP、免开端口、自动 HTTPS | 流量绕 Cloudflare 节点，首次打开慢几秒 |
| 端口绑 `127.0.0.1` | Docker 映射会绕过 ufw/iptables，不绑本地就等于全网可扫 | 需要靠 Tunnel 访问，不能直连 |
| 每日加密备份 | 硬盘坏了能原样找回 | 备份密码丢了就解不开，必须异地另存 |

## 前置条件

- 一台常开的机器（VPS、NAS、家里的旧电脑、Mac 都行）
- Docker + Docker Compose
- 一个托管在 Cloudflare 的域名
- `cloudflared`
- `sqlite3`、`openssl`（macOS 建议 `brew install openssl@3`）

## 快速开始

```bash
git clone https://github.com/AIPMAndy/FreePassword.git
cd FreePassword
cp .env.example .env
# 编辑 .env，把 DOMAIN 改成一个公网可以访问的域名
./scripts/install.sh --domain vault.example.com
```

脚本会完成：创建隧道网络 → 起容器 → 建 Cloudflare 隧道 → 加 DNS → 装常驻服务 → 生成备份密码 → 跑首次备份。

### 手动部署（不想用脚本）

```bash
mkdir -p ~/freepassword && cd ~/freepassword
# 把 docker-compose.yml 和 .env 放进来，改好 DOMAIN
docker network create tunnel
docker compose --env-file .env up -d

# 隧道
cloudflared tunnel login
cloudflared tunnel create freepassword
cloudflared tunnel route dns freepassword vault.example.com

# ~/.cloudflared/freepassword.yml
#   tunnel: <隧道ID>
#   credentials-file: <凭据JSON路径>
#   protocol: http2
#   ingress:
#     - hostname: vault.example.com
#       service: http://127.0.0.1:8081
#     - service: http_status:404
cloudflared tunnel --config ~/.cloudflared/freepassword.yml run
```

## 部署完必须做的三件事

**1. 注册主账号**

打开 `https://vault.example.com` 注册。主密码用本地密钥加密整个库，服务器上只有密文 —— 忘了谁都救不回来，Vaultwarden 没有重置功能。

**2. 关闭开放注册，并且要真的验证**

```bash
sed -i '' 's/SIGNUPS_ALLOWED=true/SIGNUPS_ALLOWED=false/' .env   # Linux 去掉 ''
docker compose --env-file .env up -d --force-recreate
```

改完**必须实测**，不要只看环境变量：

```bash
curl -s -X POST https://vault.example.com/identity/accounts/register/send-verification-email \
  -H 'Content-Type: application/json' \
  -d '{"email":"probe@example.com","name":"p"}'
```

期望返回 `Registration not allowed or user already exists`。

> ⚠️ 这里有个大坑：`GET /api/config` 里的 `disableUserRegistration` 字段**不能用来判断注册是否关闭**。
> 它对应的是 `is_signup_disabled()`，在「没配 SMTP + 允许邀请」时本来就会返回 `false`（用于决定界面是否隐藏注册入口），跟 `signups_allowed` 不是一回事。
> 另外 `/identity/accounts/register` 这个路径在新版里根本不存在，返回 404 是常态，也不能当证据。
> 详见 [docs/verify-signup.md](docs/verify-signup.md)。

**3. 开两步验证**

网页版 Settings → Security → Two-step login，恢复代码单独存一份。

## 客户端接入

装官方 Bitwarden 客户端（不是 Vaultwarden，它没有自己的 App）：

- iOS / Android：App Store / Google Play 搜 Bitwarden
- Mac：Mac App Store，装好后在 Safari 设置 → 扩展里启用
- Chrome / Edge：对应应用商店

登录页点「登录到」→ 选 **自托管** → 服务器地址填 `https://vault.example.com`。
**只填域名**，不要带端口、不要填 IP。

建议把「默认 URI 匹配检测」改成 **主机**，避免同一域名下多个自建服务串号（`a.example.com` 和 `b.example.com` 默认会被当成同一个站点）。

## 备份与恢复

```bash
# macOS：默认写 iCloud 云盘
./scripts/backup.sh

# Linux 或自选目录
BACKUP_DIR=$HOME/backups ./scripts/backup.sh

# 恢复（整个目录替换，不是覆盖）
./scripts/restore.sh ~/Downloads/freepassword-20260101-030000.tar.gz.enc
```

备份脚本做对了三件事，缺一个都可能丢数据：

1. **用 `sqlite3 .backup` 导出一致副本** —— 服务运行时直接 `cp` 数据库会拷到写了一半的库
2. **备份整个 `vw-data/`** —— 不只有 `db.sqlite3`，附件和 `rsa_key.pem` 也在这里
3. **先加密再落盘** —— 磁盘上不留明文

恢复时**整个目录替换**，别把备份内容覆盖进旧目录：旧的 `db.sqlite3-wal` 会被套到恢复的库上，数据可能错乱。

macOS 用 `launchd` 而不是 `cron`：`cron` 遇到电脑睡眠会直接跳过那一次，`launchd` 会在唤醒后补跑。

## 安全清单

- [ ] 端口绑 `127.0.0.1`，从公网直连端口打不开
- [ ] `SIGNUPS_ALLOWED=false`，且用上面的 curl 实测过
- [ ] 账号开了两步验证，恢复代码异地保存
- [ ] 备份密码抄到纸面 / 手机安全笔记，**不要只存在这台机器上**
- [ ] 导入用的 CSV 已删除，废纸篓也清空
- [ ] 真的从备份恢复过一次 —— 没恢复过的备份不算备份

## 更新

```bash
cd ~/freepassword
docker compose --env-file .env pull
docker compose --env-file .env up -d
```

## 已知限制

- **笔记本合盖休眠时手机同步会失败**，唤醒后恢复。要 24 小时在线就用常开设备，或调整电源策略。
- 国内云服务器拉 Docker Hub 镜像需要配镜像加速；GitHub 走 SSH 比 HTTPS 稳。
- 隧道流量绕 Cloudflare 海外节点，首次打开网页版可能要等十几秒，App 和插件日常使用基本无感。
- 通行密钥（Passkey）不在 CSV 导出里，迁移后需要在各站点重新添加。

## 目录结构

```
FreePassword/
├── docker-compose.yml          # 单服务，端口绑 127.0.0.1
├── .env.example                # 配置模板
├── scripts/
│   ├── install.sh              # 一键部署（macOS/Linux）
│   ├── backup.sh               # sqlite 快照 + AES-256 加密
│   └── restore.sh              # 整目录恢复
├── launchd/                    # macOS 常驻/定时任务模板
├── systemd/                    # Linux 单元模板
└── docs/
    └── verify-signup.md        # 注册开关的正确验证方法
```

## License

MIT
