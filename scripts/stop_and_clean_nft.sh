#!/usr/bin/env bash

SCRIPT_DIR="$(realpath "$(dirname "$0")")"
ROOT_DIR="${GZT_ROOT:-"$(realpath "$SCRIPT_DIR/..")"}"

LOG_DIR="$ROOT_DIR/logs"
LOG_FILE="$LOG_DIR/debug.log"

mkdir -p "$LOG_DIR" 2>/dev/null || true

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

log "Остановка nfqws и очистка nftables..."

# Остановка всех процессов nfqws
log "Остановка всех процессов nfqws..."
pkill -f "nfqws" && log "Процессы nfqws успешно остановлены" || log "Процессы nfqws не найдены"

# Очистка правил nftables
log "Очистка правил nftables, добавленных скриптом..."
if nft list table inet zapretunix >/dev/null 2>&1; then
    nft delete rule inet zapretunix output comment "Added by zapret script" >/dev/null 2>&1 || true
    nft flush table inet zapretunix >/dev/null 2>&1 || true
    nft delete table inet zapretunix >/dev/null 2>&1 && log "Таблица inet zapretunix удалена"
else
    log "Таблица inet zapretunix не найдена. Нечего очищать."
fi

log "Очистка завершена"
