#!/usr/bin/env bash
#
# FreePassword 恢复
#
# 从加密备份还原整个 vw-data 目录。
# 关键：整个目录替换，不要覆盖进旧目录 —— 旧的 db.sqlite3-wal 会被套到新库上，数据可能错乱。
#
# 用法：
#   ./scripts/restore.sh ~/Downloads/freepassword-20260101-030000.tar.gz.enc
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHIVE="${1:-}"
DATA_DIR="$ROOT/vw-data"
PASS_FILE="$ROOT/.backup-pass"

[ -n "$ARCHIVE" ] || { echo "用法: $0 <备份文件.tar.gz.enc>"; exit 1; }
[ -f "$ARCHIVE" ] || { echo "找不到备份文件: $ARCHIVE"; exit 1; }
[ -f "$PASS_FILE" ] || { echo "找不到解密密码: $PASS_FILE"; exit 1; }

if [ -x /opt/homebrew/opt/openssl@3/bin/openssl ]; then
  OPENSSL=/opt/homebrew/opt/openssl@3/bin/openssl
elif [ -x /usr/local/opt/openssl@3/bin/openssl ]; then
  OPENSSL=/usr/local/opt/openssl@3/bin/openssl
else
  OPENSSL=openssl
fi

echo "==> 停止服务"
( cd "$ROOT" && docker compose --env-file .env down ) || true

TMP="$(mktemp -d)"
echo "==> 解密并解包"
"$OPENSSL" enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
  -pass "file:$PASS_FILE" -in "$ARCHIVE" | tar -xzf - -C "$TMP"

echo "==> 校验数据库完整性"
sqlite3 "$TMP/vw-data/db.sqlite3" 'PRAGMA integrity_check;'

echo "==> 备份旧目录（不删除，留退路）"
if [ -d "$DATA_DIR" ]; then
  OLD="$ROOT/vw-data.broken.$(date +%s)"
  mv "$DATA_DIR" "$OLD"
  echo "旧数据已移到: $OLD"
fi

echo "==> 换上恢复数据"
cp -R "$TMP/vw-data" "$DATA_DIR"
rm -rf "$TMP"

echo "==> 启动服务"
( cd "$ROOT" && docker compose --env-file .env up -d )

echo
echo "恢复完成。用原主密码登录验证；确认无误后再删除 vw-data.broken.*"
