#!/usr/bin/env bash
#
# FreePassword 一键部署
#   Vaultwarden + Cloudflare Tunnel + 每日加密备份
#
# 用法：
#   ./scripts/install.sh --domain vault.example.com
#   ./scripts/install.sh --domain vault.example.com --tunnel myvault --keep 30
#
# 前置：Docker（macOS 用 Colima）、cloudflared、一个托管在 Cloudflare 的域名
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOMAIN=""
TUNNEL="freepassword"
HOST_PORT="8081"
KEEP_DAYS="30"

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --tunnel) TUNNEL="${2:-}"; shift 2 ;;
    --port)   HOST_PORT="${2:-}"; shift 2 ;;
    --keep)   KEEP_DAYS="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
done

[ -n "$DOMAIN" ] || die "必须提供 --domain，例如 --domain vault.example.com"
case "$DOMAIN" in
  *://*) die "DOMAIN 只填域名，不要带协议：--domain vault.example.com" ;;
  *.*) : ;;
  *) die "域名格式不对：$DOMAIN" ;;
esac

# ---------- 1. 依赖检查 ----------
log "检查依赖"
for bin in docker cloudflared; do
  command -v "$bin" >/dev/null 2>&1 || die "缺少 $bin，请先安装"
done
docker info >/dev/null 2>&1 || die "Docker 守护进程没起来（macOS 先执行 colima start）"
docker compose version >/dev/null 2>&1 || die "缺少 docker compose 插件"

# ---------- 2. 写入配置 ----------
log "写入 .env"
if [ -f "$ROOT/.env" ]; then
  warn ".env 已存在，保留原配置；只更新 DOMAIN"
  tmp="$(mktemp)"
  sed "s|^DOMAIN=.*|DOMAIN=https://${DOMAIN}|" "$ROOT/.env" > "$tmp"
  mv "$tmp" "$ROOT/.env"
else
  cat > "$ROOT/.env" <<EOF
DOMAIN=https://${DOMAIN}
SIGNUPS_ALLOWED=true
CONTAINER_NAME=vaultwarden
HOST_PORT=${HOST_PORT}
TZ=Asia/Shanghai
TUNNEL_NAME=${TUNNEL}
BACKUP_KEEP_DAYS=${KEEP_DAYS}
EOF
fi
chmod 600 "$ROOT/.env"

# ---------- 3. 启动 Vaultwarden ----------
log "创建共享网络 tunnel"
docker network inspect tunnel >/dev/null 2>&1 || docker network create tunnel

log "启动容器（首次会拉镜像，耐心等）"
cd "$ROOT"
docker compose --env-file .env up -d

log "等待健康检查"
for i in $(seq 1 30); do
  code="$(curl -s -o /dev/null -w '%{http_code}' -m 3 "http://127.0.0.1:${HOST_PORT}/" || true)"
  [ "$code" = "200" ] && break
  sleep 2
done
[ "$code" = "200" ] || die "服务没起来，看日志：cd $ROOT && docker compose logs -f"
log "本机已就绪：http://127.0.0.1:${HOST_PORT}"

# ---------- 4. Cloudflare 隧道 ----------
log "配置 Cloudflare 隧道：$TUNNEL"
CFG_DIR="$HOME/.cloudflared"
mkdir -p "$CFG_DIR"

if [ ! -f "$CFG_DIR/cert.pem" ]; then
  warn "还没有 cloudflared 授权，请在弹出的浏览器里选择你的域名"
  cloudflared tunnel login
fi

if cloudflared tunnel list 2>/dev/null | grep -q " ${TUNNEL} "; then
  warn "隧道 $TUNNEL 已存在，复用"
  TUNNEL_ID="$(cloudflared tunnel list --output json 2>/dev/null \
    | python3 -c "import json,sys;print(next(t['id'] for t in json.load(sys.stdin) if t['name']=='${TUNNEL}'))")"
else
  cloudflared tunnel create "$TUNNEL"
  TUNNEL_ID="$(cloudflared tunnel list --output json 2>/dev/null \
    | python3 -c "import json,sys;print(next(t['id'] for t in json.load(sys.stdin) if t['name']=='${TUNNEL}'))")"
fi
[ -n "$TUNNEL_ID" ] || die "拿不到隧道 ID"

cat > "$CFG_DIR/${TUNNEL}.yml" <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: ${CFG_DIR}/${TUNNEL_ID}.json
protocol: http2
ingress:
  - hostname: ${DOMAIN}
    service: http://127.0.0.1:${HOST_PORT}
  - service: http_status:404
EOF
chmod 600 "$CFG_DIR/${TUNNEL}.yml"

log "添加 DNS 记录"
cloudflared tunnel route dns --overwrite-dns "$TUNNEL" "$DOMAIN" || \
  warn "DNS 添加失败，可能已存在同名记录；去 Cloudflare DNS 页面确认"

# ---------- 5. 常驻服务 ----------
if [ "$(uname -s)" = "Darwin" ]; then
  log "安装 launchd 任务（隧道 + 备份）"
  mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/freepassword"

  render_plist() {
    local src="$1" dst="$2"
    sed -e "s|__TUNNEL__|${TUNNEL}|g" \
        -e "s|__CFG_DIR__|${CFG_DIR}|g" \
        -e "s|__ROOT__|${ROOT}|g" \
        -e "s|__HOME__|${HOME}|g" \
        -e "s|__LABEL_PREFIX__|com.freepassword|g" \
        "$src" > "$dst"
  }

  render_plist "$ROOT/launchd/com.freepassword.tunnel.plist.template" \
               "$HOME/Library/LaunchAgents/com.freepassword.tunnel.plist"
  render_plist "$ROOT/launchd/com.freepassword.backup.plist.template" \
               "$HOME/Library/LaunchAgents/com.freepassword.backup.plist"

  for job in tunnel backup; do
    launchctl bootout "gui/$(id -u)/com.freepassword.${job}" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.freepassword.${job}.plist"
  done
else
  log "安装 systemd 单元（隧道 + 备份）"
  warn "需要 sudo，会写入 /etc/systemd/system/"
  sed -e "s|__TUNNEL__|${TUNNEL}|g" -e "s|__CFG_DIR__|${CFG_DIR}|g" \
      "$ROOT/systemd/freepassword-tunnel.service.template" | sudo tee /etc/systemd/system/freepassword-tunnel.service >/dev/null
  sed -e "s|__ROOT__|${ROOT}|g" -e "s|__HOME__|${HOME}|g" \
      "$ROOT/systemd/freepassword-backup.service.template" | sudo tee /etc/systemd/system/freepassword-backup.service >/dev/null
  sudo cp "$ROOT/systemd/freepassword-backup.timer" /etc/systemd/system/
  sudo systemctl daemon-reload
  sudo systemctl enable --now freepassword-tunnel.service freepassword-backup.timer
fi

# ---------- 6. 备份密码 ----------
PASS_FILE="$ROOT/.backup-pass"
if [ ! -f "$PASS_FILE" ]; then
  log "生成备份加密密码"
  LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32 > "$PASS_FILE"
  echo >> "$PASS_FILE"
  chmod 600 "$PASS_FILE"
  warn "备份密码在 $PASS_FILE —— 请立刻抄到纸面或手机安全笔记，只存在这台机器上等于没有备份"
fi

# ---------- 7. 首次备份 ----------
log "执行首次备份"
BACKUP_DIR="${BACKUP_DIR:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/密码库备份}" \
  "$ROOT/scripts/backup.sh" || warn "首次备份失败，检查 OPENSSL 路径与备份目录"

echo
log "部署完成"
cat <<EOF

访问地址： https://${DOMAIN}
本机地址： http://127.0.0.1:${HOST_PORT}

接下来必须手动完成：
  1. 浏览器打开上面的地址，注册主账号（主密码只有你自己知道，服务器上只有密文）
  2. 注册完关闭开放注册：
       sed -i '' 's/SIGNUPS_ALLOWED=true/SIGNUPS_ALLOWED=false/' "$ROOT/.env"
       cd "$ROOT" && docker compose --env-file .env up -d --force-recreate
  3. 网页版 Settings → Security → Two-step login 开两步验证，恢复代码另存

验证注册是否真的关闭（重要，别只看环境变量）：
  curl -s -X POST https://${DOMAIN}/identity/accounts/register/send-verification-email \\
    -H 'Content-Type: application/json' -d '{"email":"probe@example.com","name":"p"}'
  返回 "Registration not allowed or user already exists" 才算真的关了。
EOF
