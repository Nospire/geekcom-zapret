#!/usr/bin/env bash

SCRIPT_DIR="$(realpath "$(dirname "$0")")"
BASE_DIR="$(realpath "$SCRIPT_DIR/..")"
LOG_FILE="$BASE_DIR/logs/zapret.log"

mkdir -p "$(dirname "$LOG_FILE")"

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
    nft flush table inet zapretunix >/dev/null 2>&1 || true
    nft delete table inet zapretunix >/dev/null 2>&1 && log "Таблица inet zapretunix удалена"
else
    log "Таблица inet zapretunix не найдена. Нечего очищать."
fi

log "Очистка завершена"
