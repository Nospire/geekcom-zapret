#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$BASE_DIR/logs"
LOG_FILE="$LOG_DIR/zapret.log"

log() {
    local msg="$1"
    mkdir -p "$LOG_DIR"
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$msg" | tee -a "$LOG_FILE"
}

log "Остановка nfqws и очистка nftables..."

# Остановка nfqws
if pgrep -f "nfqws" >/dev/null 2>&1; then
    sudo pkill -f "nfqws" || true
    log "Процессы nfqws остановлены"
else
    log "Процессы nfqws не найдены"
fi

# Очистка nftables
if sudo nft list table inet zapretunix >/dev/null 2>&1; then
    # Удаляем правило по комментарию (если есть)
    sudo nft delete rule inet zapretunix output comment "Added by geekcom-zapret" >/dev/null 2>&1 || true

    # Чистим и удаляем цепочку output
    sudo nft flush chain inet zapretunix output >/dev/null 2>&1 || true
    sudo nft delete chain inet zapretunix output >/dev/null 2>&1 || true

    # Удаляем таблицу
    sudo nft delete table inet zapretunix >/dev/null 2>&1 || true

    if ! sudo nft list table inet zapretunix >/dev/null 2>&1; then
        log "Таблица inet zapretunix полностью удалена"
    else
        log "Внимание: таблица inet zapretunix всё ещё существует, проверьте вручную"
    fi
else
    log "Таблица inet zapretunix не найдена. Нечего очищать."
fi

log "Остановка и очистка завершены"
