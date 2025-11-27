#!/usr/bin/env bash

# Базовые каталоги:
# ROOT/
#   bin/nfqws
#   scripts/*.sh
#   zapret-latest/
#   data/conf.env
#   logs/debug.log
SCRIPT_DIR="$(realpath "$(dirname "$0")")"
ROOT_DIR="${GZT_ROOT:-"$(realpath "$SCRIPT_DIR/..")"}"

REPO_DIR="$ROOT_DIR/zapret-latest"
NFQWS_PATH="$ROOT_DIR/bin/nfqws"
CONF_FILE="$ROOT_DIR/data/conf.env"
STOP_SCRIPT="$SCRIPT_DIR/stop_and_clean_nft.sh"
LOG_DIR="$ROOT_DIR/logs"
LOG_FILE="$LOG_DIR/debug.log"

DEBUG=false
NOINTERACTIVE=false

_term() {
    if [[ -x "$STOP_SCRIPT" ]]; then
        sudo /usr/bin/env bash "$STOP_SCRIPT" 2>&1 | while read -r line; do log "stop_script: $line"; done
    else
        log "Скрипт остановки $STOP_SCRIPT не найден или не исполняемый"
    fi
}
trap _term SIGINT SIGTERM EXIT

log() {
    mkdir -p "$LOG_DIR" 2>/dev/null || true
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

check_dependencies() {
    local deps=("nft" "grep" "sed")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            handle_error "Не установлена утилита $dep"
        fi
    done
}

load_config() {
    mkdir -p "$(dirname "$CONF_FILE")" 2>/dev/null || true

    if ! touch "$CONF_FILE" 2>/dev/null; then
        handle_error "Нет прав на запись в $CONF_FILE"
    fi

    if [ ! -f "$CONF_FILE" ] || [ ! -s "$CONF_FILE" ]; then
        log "Файл конфигурации $CONF_FILE не найден, создаю со значениями по умолчанию"
        interface="any"
        strategy=$(find "$REPO_DIR" -maxdepth 1 -type f -name "*.bat" | head -n 1 | xargs -n 1 basename 2>/dev/null)
        if [ -z "$strategy" ]; then
            handle_error "Не найден ни один .bat файл в $REPO_DIR"
        fi
        echo -e "interface=$interface\nauto_update=false\nstrategy=$strategy\ndns=disabled" > "$CONF_FILE"
    else
        # shellcheck disable=SC1090
        source "$CONF_FILE"
        interface=${interface:-any}
        if [ -z "${strategy:-}" ]; then
            strategy=$(find "$REPO_DIR" -maxdepth 1 -type f -name "*.bat" | head -n 1 | xargs -n 1 basename 2>/dev/null)
            if [ -z "$strategy" ]; then
                handle_error "Не найден ни один .bat файл в $REPO_DIR, и strategy не указан"
            fi
            echo -e "interface=$interface\nauto_update=${auto_update:-false}\nstrategy=$strategy\ndns=${dns:-disabled}" > "$CONF_FILE"
        fi
    fi
    debug_log "Загружено из conf.env: interface=$interface, strategy=$strategy, dns=${dns:-}"
}

setup_repository() {
    if [ ! -d "$REPO_DIR" ]; then
        handle_error "Каталог с .bat профилями не найден: $REPO_DIR. Скопируйте zapret-latest сюда вручную."
    fi
    log "Используется локальный каталог профилей: $REPO_DIR"
}

find_bat_files() {
    local pattern="$1"
    find "$REPO_DIR" -maxdepth 1 -type f -name "$pattern"
}

# Глобальные массивы
nft_rules=()
nfqws_params=()

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
    local bat_files=($(find_bat_files "general*.bat" | xargs -n1 echo) $(find_bat_files "discord.bat" | xargs -n1 echo))

    if [ ${#bat_files[@]} -eq 0 ]; then
        cd - >/dev/null 2>&1 || true
        handle_error "Не найдены подходящие .bat файлы"
    fi

    echo "Доступные стратегии:"
    for i in "${!bat_files[@]}"; do
        echo "$((i+1))) ${bat_files[i]}"
    done
    read -p "#? " choice
    if [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le ${#bat_files[@]} ]]; then
        strategy="${bat_files[$((choice-1))]}"
        log "Выбрана стратегия: $strategy"
        parse_bat_file "$strategy"
        cd - >/dev/null 2>&1 || true
    else
        echo "Неверный выбор. Попробуйте еще раз."
        cd - >/dev/null 2>&1 || true
        select_strategy
    fi
}

parse_bat_file() {
    local file="$1"
    local queue_num=0
    local bin_path="bin/"
    debug_log "Parsing .bat file: $file"

    nft_rules=()
    nfqws_params=()

    while IFS= read -r line; do
        debug_log "Processing line: $line"

        # Комментарии / пустые строки
        [[ "$line" =~ ^[[:space:]]*:: || -z "$line" ]] && continue

        # GameFilter сейчас не используем (игровые профили отдельно потом разрулим)
        if [[ "$line" == *"%GameFilter%"* ]]; then
            debug_log "Skipping GameFilter-specific line"
            continue
        fi

        # Подставляем пути
        line="${line//%BIN%/$bin_path}"
        line="${line//%GameFilter/}"

        if [[ "$line" =~ --filter-(tcp|udp)=([0-9,-]+)[[:space:]]*(.*?)(--new|$) ]]; then
            local protocol="${BASH_REMATCH[1]}"
            local ports="${BASH_REMATCH[2]}"
            local nfqws_args="${BASH_REMATCH[3]}"

            # Нормализуем пути списков
            nfqws_args="${nfqws_args//%LISTS%/lists/}"
            # Убираем символы продолжения строк Windows (^)
            nfqws_args="${nfqws_args//^/}"
            # Убираем висящую запятую в конце портов, типа "443,"
            ports="${ports%,}"

            # Наш nfqws не понимает L7-фильтры из этого комплекта
            if [[ "$nfqws_args" == *"--filter-l7="* ]]; then
                debug_log "Skipping unsupported l7 rule: $nfqws_args"
                continue
            fi

            # nfqws не знает "fake,multisplit" — оставляем просто fake
            nfqws_args="${nfqws_args//fake,multisplit/fake}"

            # nfqws не знает "fakedsplit" — маппим на fake,split
            nfqws_args="${nfqws_args//fakedsplit/fake,split}"

            # nfqws не знает hostlist-domains — вырезаем целиком этот флаг
            nfqws_args="$(printf '%s\n' "$nfqws_args" | sed 's/--hostlist-domains=[^ ]*//g')"

            nft_rules+=("$protocol dport {$ports} counter queue num $queue_num bypass")
            nfqws_params+=("$nfqws_args")
            debug_log "Matched protocol: $protocol, ports: $ports, queue: $queue_num"
            debug_log "NFQWS parameters for queue $queue_num: $nfqws_args"

            ((queue_num++))
        fi
    done < <(grep -v "^@echo" "$file" | grep -v "^chcp" | tr -d '\r')
}

setup_nftables() {
    local interface="$1"
    local table_name="inet zapretunix"
    local chain_name="output"
    local rule_comment="Added by zapret script"

    log "Настройка nftables..."

    if sudo nft list table $table_name >/dev/null 2>&1; then
        sudo nft flush chain $table_name $chain_name 2>/dev/null || true
        sudo nft delete chain $table_name $chain_name 2>/dev/null || true
        sudo nft delete table $table_name 2>/dev/null || true
    fi

    sudo nft add table $table_name
    sudo nft add chain $table_name $chain_name "{ type filter hook output priority 0; }"

    local oif_clause=""
    if [ -n "$interface" ] && [ "$interface" != "any" ]; then
        oif_clause="oifname \"$interface\""
    fi

    for queue_num in "${!nft_rules[@]}"; do
        sudo nft add rule $table_name $chain_name $oif_clause ${nft_rules[$queue_num]} comment \"$rule_comment\" ||
            handle_error "Ошибка при добавлении правила nftables для очереди $queue_num"
    done
}

start_nfqws() {
    log "Запуск процессов nfqws..."
    sudo pkill -f nfqws 2>/dev/null || true

    cd "$REPO_DIR" || handle_error "Не удалось перейти в директорию $REPO_DIR"
    for queue_num in "${!nfqws_params[@]}"; do
        debug_log "Запуск nfqws с параметрами: $NFQWS_PATH --daemon --qnum=$queue_num ${nfqws_params[$queue_num]}"
        eval "sudo $NFQWS_PATH --daemon --qnum=$queue_num ${nfqws_params[$queue_num]}" ||
            handle_error "Ошибка при запуске nfqws для очереди $queue_num"
    done
    cd - >/dev/null 2>&1 || true
}

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
    setup_repository

    if $NOINTERACTIVE; then
        select_strategy
        setup_nftables "$interface"
    else
        load_config
        select_strategy

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

        echo -e "interface=$interface\nauto_update=${auto_update:-false}\nstrategy=$strategy\ndns=${dns:-disabled}" > "$CONF_FILE"
    fi

    setup_nftables "$interface"
    start_nfqws
    log "Настройка успешно завершена"
}

main "$@"

sleep infinity &
wait
