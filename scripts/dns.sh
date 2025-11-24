#!/usr/bin/env bash

SCRIPT_DIR="$(realpath "$(dirname "$0")")"
BASE_DIR="$(realpath "$SCRIPT_DIR/..")"
LOG_FILE="$BASE_DIR/logs/zapret.log"

mkdir -p "$(dirname "$LOG_FILE")"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] dns.sh: $*" >> "$LOG_FILE"
}

log "вызов dns.sh с аргументами: $* (заглушка, DNS не меняется)"

exit 0
