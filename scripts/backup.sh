#!/usr/bin/env bash
#
# FreePassword 加密备份
#
# 流程：sqlite3 .backup 导出一致副本 → 连同 vw-data 其余文件打 tar
#      → AES-256-CBC + PBKDF2 加密 → 写入目标目录 → 清理过期备份
#
# 环境变量（都可覆盖）：
#   BACKUP_DIR       备份输出目录，默认 iCloud 云盘；Linux 可设成任意路径
#   BACKUP_KEEP_DAYS 保留天数，默认 30
#   OPENSSL          openssl 可执行文件；macOS 建议用 Homebrew 的 openssl@3
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_DIR="$ROOT/vw-data"
PASS_FILE="$ROOT/.backup-pass"
BACKUP_DIR="${BACKUP_DIR:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/密码库备份}"
KEEP_DAYS="${BACKUP_KEEP_DAYS:-30}"
LOG_DIR="${LOG_DIR:-$HOME/Library/Logs/freepassword}"
LOG="$LOG_DIR/backup.log"

# macOS 自带的是 LibreSSL，PBKDF2 支持不稳；优先用 Homebrew 的 openssl@3
if [ -z "${OPENSSL:-}" ]; then
  if [ -x /opt/homebrew/opt/openssl@3/bin/openssl ]; then
    OPENSSL=/opt/homebrew/opt/openssl@3/bin/openssl
  elif [ -x /usr/local/opt/openssl@3/bin/openssl ]; then
    OPENSSL=/usr/local/opt/openssl@3/bin/openssl
  else
    OPENSSL=openssl
  fi
fi

mkdir -p "$LOG_DIR" "$BACKUP_DIR"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

[ -f "$PASS_FILE" ] || { log "ERROR: 找不到备份密码 $PASS_FILE"; exit 1; }
[ -f "$DATA_DIR/db.sqlite3" ] || { log "ERROR: 找不到 $DATA_DIR/db.sqlite3"; exit 1; }

STAMP="$(date '+%Y%m%d-%H%M%S')"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 1) 一致性导出：用 sqlite 的 backup API，运行中也能拿到完整快照
sqlite3 "$DATA_DIR/db.sqlite3" ".backup '$TMP/db.sqlite3'" || {
  log "ERROR: sqlite3 导出失败"; exit 1; }
log "数据库已导出一致副本"

# 2) 组装：快照 + 附件/密钥等；排除运行时临时文件
mkdir -p "$TMP/vw-data"
mv "$TMP/db.sqlite3" "$TMP/vw-data/db.sqlite3"
rsync -a --exclude 'db.sqlite3' --exclude 'db.sqlite3-shm' --exclude 'db.sqlite3-wal' \
      --exclude 'tmp/' --exclude 'icon_cache/' \
      "$DATA_DIR/" "$TMP/vw-data/" 2>/dev/null || \
  cp -R "$DATA_DIR/." "$TMP/vw-data/" 2>/dev/null || true

# 3) 流式打包 + 加密，磁盘上不留明文
ARCHIVE="$BACKUP_DIR/freepassword-$STAMP.tar.gz.enc"
tar -czf - -C "$TMP" vw-data \
  | "$OPENSSL" enc -aes-256-cbc -pbkdf2 -iter 200000 -salt \
      -pass "file:$PASS_FILE" -out "$ARCHIVE"

chmod 600 "$ARCHIVE"
log "备份完成: $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))"

# 4) 清理过期备份
del=0
while IFS= read -r old; do rm -f "$old"; del=$((del + 1)); done < \
  <(find "$BACKUP_DIR" -name 'freepassword-*.tar.gz.enc' -type f -mtime +"$KEEP_DAYS")
[ "$del" -gt 0 ] && log "清理了 $del 个超过 $KEEP_DAYS 天的旧备份"

log "当前共 $(find "$BACKUP_DIR" -name 'freepassword-*.tar.gz.enc' -type f | wc -l | tr -d ' ') 份备份"
