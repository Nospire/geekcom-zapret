#!/usr/bin/env bash

SCRIPT_DIR="$(realpath "$(dirname "$0")")"
ROOT_DIR="${GZT_ROOT:-"$(realpath "$SCRIPT_DIR/..")"}"

LOG_DIR="$ROOT_DIR/logs"
LOG_FILE="$LOG_DIR/debug.log"

mkdir -p "$LOG_DIR" 2>/dev/null || true

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log "Остановка nfqws и очистка nftables..."

# Остановка всех процессов nfqws
if pgrep -f "nfqws" >/dev/null 2>&1; then
    pkill -f "nfqws" && log "Процессы nfqws остановлены"
else
    log "Процессы nfqws не найдены"
fi

# Очистка таблицы inet zapretunix
if nft list table inet zapretunix >/dev/null 2>&1; then
    log "Удаляю таблицу inet zapretunix..."
    nft flush table inet zapretunix >/dev/null 2>&1 || true
    nft delete table inet zapretunix >/dev/null 2>&1 && log "Таблица inet zapretunix удалена"
else
    log "Таблица inet zapretunix не найдена, нечего чистить"
fi

log "Очистка завершена"
