#!/usr/bin/env bash

set -euo pipefail

# ==== БАЗОВЫЕ КОНСТАНТЫ ====

SCRIPT_DIR="$(realpath "$(dirname "$0")")"
BASE_DIR="$(realpath "$SCRIPT_DIR/..")"

REPO_DIR="$BASE_DIR/zapret-latest"
NFQWS_PATH="$BASE_DIR/bin/nfqws"
CONF_FILE="$BASE_DIR/config/zapret.conf"
STOP_SCRIPT="$BASE_DIR/scripts/stop_and_clean_nft.sh"
DNS_SCRIPT="$BASE_DIR/scripts/dns.sh"
LOG_FILE="$BASE_DIR/logs/zapret.log"

mkdir -p "$(dirname "$CONF_FILE")" "$(dirname "$LOG_FILE")"

DEBUG=false
NOINTERACTIVE=false

declare -a nft_rules=()
declare -a nfqws_params=()

# ==== ЛОГИРОВАНИЕ ====

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

debug_log() {
    if $DEBUG; then
        log "[DEBUG] $1"
    fi
}

handle_error() {
    log "Ошибка: $1" >&2
    exit 1
}

# ==== ОБРАБОТКА ЗАВЕРШЕНИЯ ====

_term() {
    if [[ -x "$STOP_SCRIPT" ]]; then
        /usr/bin/env bash "$STOP_SCRIPT" 2>&1 | while read -r line; do log "stop_script: $line"; done
    else
        log "Скрипт остановки $STOP_SCRIPT не найден или не исполняемый"
    fi
}
trap _term SIGINT SIGTERM EXIT

# ==== ВЫБОР STRATEGY ПО УМОЛЧАНИЮ ====

default_strategy() {
    local f

    # Сначала пробуем general*.bat
    f=$(find "$REPO_DIR" -maxdepth 1 -type f -name "general*.bat" | sort | head -n1 || true)
    if [ -n "${f:-}" ]; then
        basename "$f"
        return 0
    fi

    # Потом discord.bat
    f=$(find "$REPO_DIR" -maxdepth 1 -type f -name "discord.bat" | sort | head -n1 || true)
    if [ -n "${f:-}" ]; then
        basename "$f"
        return 0
    fi

    # Потом любые .bat, кроме service* и check_updates*
    f=$(find "$REPO_DIR" -maxdepth 1 -type f -name "*.bat" \
        ! -name "service*.bat" ! -name "check_updates*.bat" \
        | sort | head -n1 || true)
    if [ -n "${f:-}" ]; then
        basename "$f"
        return 0
    fi

    return 1
}

# ==== ПРОВЕРКА ЗАВИСИМОСТЕЙ ====

check_dependencies() {
    local deps=("nft" "grep" "sed" "sudo")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            handle_error "Не установлена утилита $dep"
        fi
    done

    if [ ! -x "$NFQWS_PATH" ]; then
        handle_error "Бинарник nfqws не найден или не исполняемый: $NFQWS_PATH"
    fi

    if [ ! -d "$REPO_DIR" ]; then
        handle_error "Каталог с .bat файлами не найден: $REPO_DIR"
    fi
}

# ==== КОНФИГ ====

load_config() {
    if ! touch "$CONF_FILE" 2>/dev/null; then
        handle_error "Нет прав на запись в $CONF_FILE"
    fi

    if [ ! -f "$CONF_FILE" ]; then
        log "Файл конфигурации $CONF_FILE не найден, создаю со значениями по умолчанию"
        interface="any"
        if ! strategy="$(default_strategy)"; then
            handle_error "Не найден ни один подходящий .bat файл в $REPO_DIR"
        fi
        dns="disabled"
        {
            echo "interface=$interface"
            echo "strategy=$strategy"
            echo "dns=$dns"
        } > "$CONF_FILE"
    else
        # shellcheck disable=SC1090
        source "$CONF_FILE" || true
        interface=${interface:-any}
        dns=${dns:-disabled}
        strategy=${strategy:-}

        # Если стратегия пустая или служебная — переопределяем
        if [ -z "$strategy" ] || [[ "$strategy" == service*.bat ]] || [[ "$strategy" == check_updates*.bat ]]; then
            log "Указана служебная или пустая strategy='$strategy', выбираю другую по умолчанию"
            if ! strategy="$(default_strategy)"; then
                handle_error "Не найден ни один подходящий .bat файл в $REPO_DIR"
            fi
            {
                echo "interface=$interface"
                echo "strategy=$strategy"
                echo "dns=$dns"
            } > "$CONF_FILE"
        fi
    fi
    debug_log "Загружен конфиг: interface=$interface, strategy=$strategy, dns=$dns"
}

# ==== ПОИСК/ВЫБОР .BAT ====

find_bat_files() {
    local pattern="$1"
    find "$REPO_DIR" -maxdepth 1 -type f -name "$pattern"
}

parse_bat_file() {
    local file="$1"
    local queue_num=0
    local bin_path="bin/"
    debug_log "Разбор .bat файла: $file"

    nft_rules=()
    nfqws_params=()

    while IFS= read -r line; do
        debug_log "Строка: $line"

        [[ "$line" =~ ^[[:space:]]*:: || -z "$line" ]] && continue

        line="${line//%BIN%/$bin_path}"
        line="${line//%GameFilter/}"

        if [[ "$line" =~ --filter-(tcp|udp)=([0-9,-]+)[[:space:]]*(.*?)(--new|$) ]]; then
            local protocol="${BASH_REMATCH[1]}"
            local ports="${BASH_REMATCH[2]}"
            local nfqws_args="${BASH_REMATCH[3]}"

            nfqws_args="${nfqws_args//%LISTS%/lists/}"

            nft_rules+=("$protocol dport {$ports} counter queue num $queue_num bypass")
            nfqws_params+=("$nfqws_args")

            debug_log "Совпадение: protocol=$protocol ports=$ports queue=$queue_num"
            debug_log "NFQWS params[$queue_num]: $nfqws_args"

            ((queue_num++))
        fi
    done < <(grep -v "^@echo" "$file" | grep -v "^chcp" | tr -d '\r')

    debug_log "Итог: найдено ${#nft_rules[@]} nft-правил и ${#nfqws_params[@]} наборов параметров"
}

select_strategy() {
    cd "$REPO_DIR" || handle_error "Не удалось перейти в директорию $REPO_DIR"

    if $NOINTERACTIVE; then
        debug_log "Неинтерактивный режим, strategy=$strategy"
        if [ ! -f "$strategy" ]; then
            handle_error "Указанный .bat файл стратегии $strategy не найден"
        fi
        parse_bat_file "$strategy"
        cd - >/dev/null 2>&1 || true
        return
    fi

    local IFS=$'\n'
    local bat_files=($(find_bat_files "general*.bat" | xargs -n1 echo 2>/dev/null) $(find_bat_files "discord.bat" | xargs -n1 echo 2>/dev/null))

    if [ ${#bat_files[@]} -eq 0 ]; then
        cd - >/dev/null 2>&1 || true
        handle_error "Не найдены подходящие .bat файлы (general*/discord)"
    fi

    echo "Доступные стратегии:"
    for i in "${!bat_files[@]}"; do
        echo "$((i+1))) ${bat_files[i]}"
    done
    read -rp "#? " choice
    if [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le ${#bat_files[@]} ]]; then
        strategy="${bat_files[$((choice-1))]}"
        strategy="$(basename "$strategy")"
        log "Выбрана стратегия: $strategy"
        parse_bat_file "$strategy"
        cd - >/dev/null 2>&1 || true
    else
        echo "Неверный выбор. Попробуйте еще раз."
        cd - >/dev/null 2>&1 || true
        select_strategy
    fi
}

# ==== NFTABLES ====

setup_nftables() {
    local iface="$1"
    local table_name="inet zapretunix"
    local chain_name="output"
    local rule_comment="Added by geekcom-zapret"

    log "Настройка nftables..."

    if sudo nft list tables 2>/dev/null | grep -q "$table_name"; then
        sudo nft flush chain "$table_name" "$chain_name" 2>/dev/null || true
        sudo nft delete chain "$table_name" "$chain_name" 2>/dev/null || true
        sudo nft delete table "$table_name" 2>/dev/null || true
    fi

    sudo nft add table "$table_name"
    sudo nft add chain "$table_name" "$chain_name" "{ type filter hook output priority 0; }"

    local oif_clause=""
    if [ -n "$iface" ] && [ "$iface" != "any" ]; then
        oif_clause="oifname \"$iface\""
    fi

    if [ "${#nft_rules[@]}" -eq 0 ]; then
        log "Предупреждение: nft_rules пустой, правила не будут добавлены"
        return 0
    fi

    for queue_num in "${!nft_rules[@]}"; do
        sudo nft add rule "$table_name" "$chain_name" $oif_clause ${nft_rules[$queue_num]} comment \"$rule_comment\" ||
            handle_error "Ошибка при добавлении правила nftables для очереди $queue_num"
    done
}

# ==== NFQWS ====

start_nfqws() {
    log "Запуск процессов nfqws..."
    sudo pkill -f nfqws 2>/dev/null || true
    cd "$BASE_DIR" || handle_error "Не удалось перейти в директорию $BASE_DIR"

    if [ "${#nfqws_params[@]}" -eq 0 ]; then
        log "Предупреждение: nfqws_params пустой, процессы nfqws не будут запущены"
        return 0
    fi

    for queue_num in "${!nfqws_params[@]}"; do
        debug_log "Запуск nfqws: $NFQWS_PATH --daemon --qnum=$queue_num ${nfqws_params[$queue_num]}"
        eval "sudo \"$NFQWS_PATH\" --daemon --qnum=$queue_num ${nfqws_params[$queue_num]}" ||
            handle_error "Ошибка при запуске nfqws для очереди $queue_num"
    done
}

# ==== MAIN ====

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -debug)
                DEBUG=true
                shift
                ;;
            -nointeractive)
                NOINTERACTIVE=true
                shift
                load_config
                ;;
            *)
                break
                ;;
        esac
    done

    check_dependencies

    if ! $NOINTERACTIVE; then
        load_config
    fi

    select_strategy

    if ! $NOINTERACTIVE; then
        local interfaces=("any" $(ls /sys/class/net 2>/dev/null | grep -v lo))
        if [ ${#interfaces[@]} -eq 0 ]; then
            handle_error "Не найдены сетевые интерфейсы"
        fi
        echo "Доступные сетевые интерфейсы:"
        select interface in "${interfaces[@]}"; do
            if [ -n "$interface" ]; then
                log "Выбран интерфейс: $interface"
                break
            fi
            echo "Неверный выбор. Попробуйте еще раз."
        done
    fi

    # DNS пока заглушка
    if [ "${dns:-disabled}" = "enabled" ] && [ -x "$DNS_SCRIPT" ]; then
        bash "$DNS_SCRIPT" set 2>&1 | while read -r line; do log "dns.sh: $line"; done || log "dns.sh завершился с ошибкой (заглушка)"
    fi

    setup_nftables "$interface"
    start_nfqws
    log "Настройка успешно завершена"

    sleep infinity &
    wait
}

main "$@"
