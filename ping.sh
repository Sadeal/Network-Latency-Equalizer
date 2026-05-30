#!/bin/bash

DEBUG=0

debug_log() {
    if [ $DEBUG -eq 1 ]; then
        echo "[DEBUG $(date '+%H:%M:%S')] $1" >&2
    fi
}

info_log() {
    echo "[INFO $(date '+%H:%M:%S')] $1"
}

error_log() {
    echo "[ERROR $(date '+%H:%M:%S')] $1" >&2
}

if [ "$EUID" -ne 0 ]; then
    error_log "Скрипт должен запускаться с правами root (sudo)"
    exit 1
fi

if [ "$#" -lt 3 ] || [ $(( $# % 3 )) -ne 0 ]; then
    error_log "Неправильные аргументы"
    echo "Использование: $0 PORT1 PING_PORT1 MIN_PING1 PORT2 PING_PORT2 MIN_PING2 ..."
    echo "Пример: $0 27055 27056 30"
    exit 1
fi

is_integer() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

validate_port() {
    local port=$1
    is_integer "$port" && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

validate_delay() {
    local delay=$1
    is_integer "$delay" && [ "$delay" -ge 0 ] && [ "$delay" -le 60000 ]
}

validate_ipv4() {
    local ip=$1
    local octets
    local octet

    IFS='.' read -ra octets <<< "$ip"
    [ "${#octets[@]}" -eq 4 ] || return 1

    for octet in "${octets[@]}"; do
        is_integer "$octet" && [ "$octet" -le 255 ] || return 1
    done
}

require_command() {
    local command_name=$1
    if ! command -v "$command_name" > /dev/null 2>&1; then
        error_log "Не найдена обязательная команда: $command_name"
        return 1
    fi
}

for command_name in ip tc tcpdump conntrack awk sort tail wc mktemp; do
    require_command "$command_name" || exit 1
done

detect_interface() {
    local iface
    iface=$(ip -4 route show default | awk '{
        for (i = 1; i <= NF; i++) {
            if ($i == "dev") {
                print $(i + 1)
                exit
            }
        }
    }')
    if [ -z "$iface" ]; then
        iface=$(ip -4 route get 8.8.8.8 2>/dev/null | awk '{
            for (i = 1; i <= NF; i++) {
                if ($i == "dev") {
                    print $(i + 1)
                    exit
                }
            }
        }')
    fi
    echo "$iface"
}

get_interface_ip() {
    local iface=$1
    local ip
    ip=$(ip -4 -o addr show dev "$iface" scope global | awk '{
        split($4, address, "/")
        print address[1]
        exit
    }')
    echo "$ip"
}

INTERFACE=$(detect_interface)
if [ -z "$INTERFACE" ]; then
    error_log "Не удалось определить сетевой интерфейс"
    exit 1
fi

SERVER_IP=$(get_interface_ip "$INTERFACE")
if [ -z "$SERVER_IP" ]; then
    error_log "Не удалось определить IPv4-адрес интерфейса $INTERFACE"
    exit 1
fi

info_log "Интерфейс: $INTERFACE, IP: $SERVER_IP"

declare -A PORT_DELAYS
declare -A PORT_PING_PORTS
declare -A KEY_CLASSID
declare -A KEY_CURRENT_PING
declare -A KEY_ADDED_DELAY
declare -A KEY_HAS_RULE
declare -A KEY_LAST_SEEN
declare -A KEY_PING_HISTORY
declare -A KEY_BASE_PING
declare -A KEY_STABLE_COUNTER
declare -A KEY_DELAY_CHANGED_AT
declare -A KEY_CUSTOM_TARGET
declare -A KEY_PREV_CUSTOM_TARGET

UPPER_HYSTERESIS=2
LOWER_HYSTERESIS=0

PING_SAMPLES=5
MIN_SAMPLES_BEFORE_ACTION=3
CLIENT_TIMEOUT=30

MIN_DELAY_INCREASE=1
MIN_DELAY_DECREASE=2

STABILIZATION_CYCLES=3
DELAY_SETTLE_TIME=3
WATCHDOG_MAX_EMPTY_CYCLES=3
MAX_RUNTIME_SECONDS=7200
EMPTY_UDP_RESTART_MARKER="/run/ping-manager-empty-udp-restart.lock"

TC_INITIALIZED=0
UDP_LISTENER_PID=0
if ! UDP_DATA_FILE=$(mktemp /tmp/ping_udp_data.XXXXXX); then
    error_log "Не удалось создать временный файл для UDP-данных"
    exit 1
fi
if ! UDP_HEARTBEAT_FILE=$(mktemp /tmp/ping_udp_heartbeat.XXXXXX); then
    error_log "Не удалось создать временный файл для UDP-watchdog"
    rm -f "$UDP_DATA_FILE"
    exit 1
fi

EMPTY_UDP_RESTART_LATCHED=0
if [ -e "$EMPTY_UDP_RESTART_MARKER" ]; then
    EMPTY_UDP_RESTART_LATCHED=1
fi

cleanup() {
    local exit_code=${1:-0}

    if [ "$CLEANUP_DONE" -eq 1 ]; then
        return
    fi
    CLEANUP_DONE=1

    echo ""
    info_log "=== Завершение работы ==="
    
    if [ "$UDP_LISTENER_PID" -ne 0 ]; then
        kill "$UDP_LISTENER_PID" 2>/dev/null
        wait "$UDP_LISTENER_PID" 2>/dev/null
    fi
    rm -f "$UDP_DATA_FILE" "$UDP_HEARTBEAT_FILE"
    
    if [ "$TC_INITIALIZED" -eq 1 ]; then
        tc qdisc del dev "$INTERFACE" root 2>/dev/null
        info_log "TC правила удалены"
    fi

    return "$exit_code"
}

CLEANUP_DONE=0
trap 'exit 0' SIGINT SIGTERM
trap 'cleanup $?' EXIT

request_restart() {
    error_log "$1"
    error_log "Завершаем процесс, systemd должен запустить его заново"
    exit 1
}

latch_empty_udp_restart() {
    if ! printf '%s\n' "$(date +%s)" > "$EMPTY_UDP_RESTART_MARKER"; then
        error_log "Не удалось записать marker $EMPTY_UDP_RESTART_MARKER"
        EMPTY_UDP_RESTART_LATCHED=1
        return 1
    fi

    EMPTY_UDP_RESTART_LATCHED=1
}

reset_empty_udp_restart_latch() {
    if [ "$EMPTY_UDP_RESTART_LATCHED" -eq 1 ] || [ -e "$EMPTY_UDP_RESTART_MARKER" ]; then
        if ! rm -f "$EMPTY_UDP_RESTART_MARKER"; then
            error_log "Не удалось удалить marker $EMPTY_UDP_RESTART_MARKER"
            return 1
        fi

        EMPTY_UDP_RESTART_LATCHED=0
        info_log "Получен валидный UDP-отчёт с IP: рестарт по трём пустым циклам снова разрешён"
    fi
}

TEMP_ARGS=("$@")
while [ ${#TEMP_ARGS[@]} -gt 0 ]; do
    PORT=${TEMP_ARGS[0]}
    PING_PORT=${TEMP_ARGS[1]}
    MIN_PING=${TEMP_ARGS[2]}

    if ! validate_port "$PORT"; then
        error_log "Некорректный игровой порт: $PORT"
        exit 1
    fi
    if ! validate_port "$PING_PORT"; then
        error_log "Некорректный ping-порт: $PING_PORT"
        exit 1
    fi
    if ! validate_delay "$MIN_PING"; then
        error_log "Некорректный минимальный пинг: $MIN_PING"
        exit 1
    fi
    if [ -n "${PORT_DELAYS[$PORT]+x}" ]; then
        error_log "Игровой порт указан несколько раз: $PORT"
        exit 1
    fi
    
    PORT_DELAYS[$PORT]=$MIN_PING
    PORT_PING_PORTS[$PORT]=$PING_PORT
    
    info_log "Порт: $PORT -> мин. пинг: ${MIN_PING}ms, пинг-порт: $PING_PORT"
    
    TEMP_ARGS=("${TEMP_ARGS[@]:3}")
done

start_udp_listener() {
    local ip=$1
    local ports_list=$2
    
    local port_filter=""
    for port in $ports_list; do
        if [ -z "$port_filter" ]; then
            port_filter="udp port $port"
        else
            port_filter="$port_filter or udp port $port"
        fi
    done
    
    local final_filter="($port_filter) and dst host $ip"
    
    info_log "Запуск UDP listener (tcpdump) с фильтром: $final_filter"
    
    (
        local packet_ping_port=""
        local header_pattern
        header_pattern="> ${ip//./\\.}\\.([0-9]+): UDP"

        tcpdump -i any -n -l -A "$final_filter" 2>/dev/null | \
        while read -r line; do
            if [[ "$line" =~ $header_pattern ]]; then
                packet_ping_port="${BASH_REMATCH[1]}"
                continue
            fi

            if [ -z "$packet_ping_port" ]; then
                continue
            fi

            if [[ "$line" =~ ([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})\|([0-9]+)\|([0-9]+) ]]; then
                client_ip="${BASH_REMATCH[1]}"
                ping_value="${BASH_REMATCH[2]}"
                set_value="${BASH_REMATCH[3]}"
                
                if validate_ipv4 "$client_ip" && validate_delay "$ping_value" && validate_delay "$set_value"; then
                    rm -f "$EMPTY_UDP_RESTART_MARKER" || error_log "Не удалось удалить marker $EMPTY_UDP_RESTART_MARKER"
                    echo "$(date +%s)|$packet_ping_port|$client_ip|$ping_value|$set_value" >> "$UDP_DATA_FILE"
                    echo "$(date +%s)|$RANDOM" > "$UDP_HEARTBEAT_FILE"
                    debug_log "UDP Packet: port=$packet_ping_port, $client_ip -> ping=${ping_value}ms, set=${set_value}ms"
                fi
                packet_ping_port=""
            elif [[ "$line" =~ ([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})\|([0-9]+) ]]; then
                client_ip="${BASH_REMATCH[1]}"
                ping_value="${BASH_REMATCH[2]}"
                
                if validate_ipv4 "$client_ip" && validate_delay "$ping_value"; then
                    rm -f "$EMPTY_UDP_RESTART_MARKER" || error_log "Не удалось удалить marker $EMPTY_UDP_RESTART_MARKER"
                    echo "$(date +%s)|$packet_ping_port|$client_ip|$ping_value|0" >> "$UDP_DATA_FILE"
                    echo "$(date +%s)|$RANDOM" > "$UDP_HEARTBEAT_FILE"
                    debug_log "UDP Packet (legacy): port=$packet_ping_port, $client_ip -> ping=${ping_value}ms, set=0"
                fi
                packet_ping_port=""
            fi
        done
    ) &
    
    UDP_LISTENER_PID=$!
    debug_log "UDP listener PID: $UDP_LISTENER_PID"
}

get_client_pings() {
    local current_time
    current_time=$(date +%s)
    local max_age=10
    
    declare -A latest_pings
    declare -A latest_sets
    
    if [ ! -s "$UDP_DATA_FILE" ]; then
        return
    fi
    
    while IFS='|' read -r timestamp ping_port client_ip ping_value set_value; do
        if is_integer "$timestamp" && validate_port "$ping_port" && validate_ipv4 "$client_ip" && validate_delay "$ping_value"; then
            local age=$((current_time - timestamp))
            if [ $age -le $max_age ]; then
                local report_key="$ping_port|$client_ip"
                latest_pings["$report_key"]=$ping_value
                latest_sets["$report_key"]=${set_value:-0}
            fi
        fi
    done < "$UDP_DATA_FILE"
    
    if [ "$(wc -l < "$UDP_DATA_FILE")" -gt 100 ]; then
        tail -100 "$UDP_DATA_FILE" > "${UDP_DATA_FILE}.tmp"
        mv "${UDP_DATA_FILE}.tmp" "$UDP_DATA_FILE"
    fi
    
    for report_key in "${!latest_pings[@]}"; do
        echo "$report_key|${latest_pings[$report_key]}|${latest_sets[$report_key]}"
    done
}

calculate_average_ping() {
    local history=$1
    local sum=0
    local count=0
    
    IFS=',' read -ra pings <<< "$history"
    for ping in "${pings[@]}"; do
        if [ -n "$ping" ] && [ "$ping" -gt 0 ]; then
            sum=$((sum + ping))
            count=$((count + 1))
        fi
    done
    
    if [ $count -gt 0 ]; then
        echo $((sum / count))
    else
        echo 0
    fi
}

add_ping_to_history() {
    local key=$1
    local ping=$2
    
    local history="${KEY_PING_HISTORY[$key]}"
    
    if [ -z "$history" ]; then
        KEY_PING_HISTORY[$key]="$ping"
    else
        IFS=',' read -ra pings <<< "$history"
        local count=${#pings[@]}
        
        if [ $count -ge $PING_SAMPLES ]; then
            pings=("${pings[@]:1}")
        fi
        
        pings+=("$ping")
        KEY_PING_HISTORY[$key]=$(IFS=','; echo "${pings[*]}")
    fi
}

get_history_count() {
    local key=$1
    local history="${KEY_PING_HISTORY[$key]}"
    
    if [ -z "$history" ]; then
        echo 0
        return
    fi
    
    IFS=',' read -ra pings <<< "$history"
    echo ${#pings[@]}
}

clear_ping_history() {
    local key=$1
    KEY_PING_HISTORY[$key]=""
    debug_log "  $key: история пингов очищена"
}

get_effective_target() {
    local port=$1
    local client_ip=$2
    local key="$port|$client_ip"
    
    local min_ping=${PORT_DELAYS[$port]}
    local custom_target=${KEY_CUSTOM_TARGET[$key]:-0}
    
    if [ "$custom_target" -gt 0 ] && [ "$custom_target" -gt "$min_ping" ]; then
        echo "$custom_target"
    else
        echo "$min_ping"
    fi
}

TC_RATE="1000mbit"
MAX_CLASSID=65534

format_tc_classid() {
    printf '%x' "$1"
}

allocate_classid_for_key() {
    local key=$1

    if [ -n "${KEY_CLASSID[$key]}" ]; then
        return
    fi

    if [ "$CLASSID_COUNTER" -gt "$MAX_CLASSID" ]; then
        request_restart "Достигнут лимит classid ($MAX_CLASSID)"
    fi

    KEY_CLASSID[$key]=$CLASSID_COUNTER
    CLASSID_COUNTER=$((CLASSID_COUNTER + 1))
}

delete_tc_rule() {
    local classid=$1
    local tc_classid
    tc_classid=$(format_tc_classid "$classid")

    tc filter del dev "$INTERFACE" parent 1: protocol ip prio "$classid" u32 2>/dev/null
    tc qdisc del dev "$INTERFACE" parent 1:"$tc_classid" 2>/dev/null
    tc class del dev "$INTERFACE" classid 1:"$tc_classid" 2>/dev/null
}

set_delay_for_key() {
    local port=$1
    local ip=$2
    local delay=$3
    local classid=$4
    local key="$port|$ip"
    local current_time=$(date +%s)
    local tc_classid
    
    if [ "$delay" -le 0 ]; then
        debug_log "  $key: delay <= 0, убираем netem"
        
        if [ -n "${KEY_CLASSID[$key]}" ]; then
            delete_tc_rule "${KEY_CLASSID[$key]}"
        fi
        
        KEY_ADDED_DELAY[$key]=0
        KEY_HAS_RULE[$key]=0
        clear_ping_history "$key"
        KEY_DELAY_CHANGED_AT[$key]=$current_time
        KEY_STABLE_COUNTER[$key]=$STABILIZATION_CYCLES
        
        info_log "✗ УБРАНО: $key | задержка больше не нужна"
        return
    fi

    tc_classid=$(format_tc_classid "$classid")
    
    if [ -n "${KEY_CLASSID[$key]}" ] && [ "${KEY_HAS_RULE[$key]}" == "1" ]; then
        delete_tc_rule "${KEY_CLASSID[$key]}"
    fi
    
    if ! tc class add dev "$INTERFACE" parent 1: classid 1:"$tc_classid" htb rate "$TC_RATE" ceil "$TC_RATE" 2>/dev/null; then
        error_log "Не удалось добавить TC-класс для $key"
        return 1
    fi
    if ! tc qdisc add dev "$INTERFACE" parent 1:"$tc_classid" handle "$tc_classid:" netem delay "${delay}ms" 2>/dev/null; then
        error_log "Не удалось добавить netem для $key"
        delete_tc_rule "$classid"
        return 1
    fi
    
    if ! tc filter add dev "$INTERFACE" parent 1: protocol ip prio "$classid" u32 \
        match ip protocol 17 0xff \
        match ip sport "$port" 0xffff \
        match ip dst "$ip" \
        flowid 1:"$tc_classid" 2>/dev/null; then
        error_log "Не удалось добавить TC-фильтр для $key"
        delete_tc_rule "$classid"
        return 1
    fi
    
    KEY_CLASSID[$key]=$classid
    KEY_ADDED_DELAY[$key]=$delay
    KEY_HAS_RULE[$key]=1
    clear_ping_history "$key"
    KEY_DELAY_CHANGED_AT[$key]=$current_time
    KEY_STABLE_COUNTER[$key]=$STABILIZATION_CYCLES
    
    info_log "✓ УСТАНОВЛЕНО: $key | Добавлено: ${delay}ms"
}

remove_client_completely() {
    local port=$1
    local ip=$2
    local key="$port|$ip"
    
    local classid="${KEY_CLASSID[$key]}"
    if [ -n "$classid" ] && [ "${KEY_HAS_RULE[$key]}" == "1" ]; then
        delete_tc_rule "$classid"
    fi
    
    unset KEY_CURRENT_PING[$key]
    unset KEY_ADDED_DELAY[$key]
    unset KEY_CLASSID[$key]
    unset KEY_HAS_RULE[$key]
    unset KEY_LAST_SEEN[$key]
    unset KEY_PING_HISTORY[$key]
    unset KEY_BASE_PING[$key]
    unset KEY_STABLE_COUNTER[$key]
    unset KEY_DELAY_CHANGED_AT[$key]
    unset KEY_CUSTOM_TARGET[$key]
    unset KEY_PREV_CUSTOM_TARGET[$key]
    
    info_log "✗ ОТКЛЮЧИЛСЯ: $key | Правила удалены (таймаут)"
}

handle_custom_target_change() {
    local port=$1
    local client_ip=$2
    local key="$port|$client_ip"
    
    local current_set=${KEY_CUSTOM_TARGET[$key]:-0}
    local prev_set=${KEY_PREV_CUSTOM_TARGET[$key]:-INIT}
    
    if [ "$prev_set" == "INIT" ]; then
        KEY_PREV_CUSTOM_TARGET[$key]=$current_set
        return 1
    fi
    
    if [ "$current_set" == "$prev_set" ]; then
        return 1
    fi
    
    KEY_PREV_CUSTOM_TARGET[$key]=$current_set
    
    local effective_target=$(get_effective_target "$port" "$client_ip")
    local min_ping=${PORT_DELAYS[$port]}
    
    info_log "⚡ $key: set изменён $prev_set -> $current_set (effective: ${effective_target}ms, min: ${min_ping}ms)"
    
    local added_delay=${KEY_ADDED_DELAY[$key]:-0}
    local current_ping=${KEY_CURRENT_PING[$key]:-0}
    
    if [ "$current_ping" -le 0 ]; then
        info_log "  → Нет данных о пинге, сброс состояния"
        clear_ping_history "$key"
        KEY_STABLE_COUNTER[$key]=0
        KEY_DELAY_CHANGED_AT[$key]=0
        return 0
    fi
    
    local base_ping=$((current_ping - added_delay))
    if [ "$base_ping" -lt 1 ]; then
        base_ping=1
    fi
    
    local needed_delay=$((effective_target - base_ping))
    if [ "$needed_delay" -lt 0 ]; then
        needed_delay=0
    fi
    
    allocate_classid_for_key "$key"
    
    info_log "  → Пересчёт: base=${base_ping}ms, target=${effective_target}ms, delay: ${added_delay}ms -> ${needed_delay}ms"
    if ! set_delay_for_key "$port" "$client_ip" "$needed_delay" "${KEY_CLASSID[$key]}"; then
        request_restart "Не удалось обновить TC-правило для $key"
    fi
    
    return 0
}

info_log "=== Инициализация TC ==="

tc qdisc del dev "$INTERFACE" root 2>/dev/null

tc qdisc add dev "$INTERFACE" root handle 1: htb default 1
if [ $? -ne 0 ]; then
    error_log "Ошибка TC: не удалось добавить root htb"
    exit 1
fi

if ! tc class add dev "$INTERFACE" parent 1: classid 1:1 htb rate "$TC_RATE" ceil "$TC_RATE" 2>/dev/null; then
    error_log "Ошибка TC: не удалось добавить класс по умолчанию"
    exit 1
fi

TC_INITIALIZED=1
info_log "TC (HTB) инициализирован успешно"

ALL_PING_PORTS=""
declare -A SEEN_PING_PORTS
for p in "${PORT_PING_PORTS[@]}"; do
    if [ -z "${SEEN_PING_PORTS[$p]+x}" ]; then
        ALL_PING_PORTS="$ALL_PING_PORTS $p"
        SEEN_PING_PORTS[$p]=1
    fi
done

start_udp_listener "$SERVER_IP" "$ALL_PING_PORTS"
sleep 2

if ! kill -0 "$UDP_LISTENER_PID" 2>/dev/null; then
    error_log "UDP listener не запустился! Проверьте tcpdump."
    exit 1
fi

echo ""
info_log "=== Скрипт запущен ==="
info_log "Мониторинг портов: ${!PORT_DELAYS[@]}"
info_log "UDP Listener работает на $SERVER_IP"
info_log "Гистерезис: нейтральная зона [TARGET, TARGET+1], добавление если < TARGET, удаление если >= TARGET+2"
if [ "$EMPTY_UDP_RESTART_LATCHED" -eq 1 ]; then
    info_log "UDP watchdog: рестарт по пустым циклам уже выполнен, ждём валидный отчёт с IP"
fi
info_log "Для остановки нажмите Ctrl+C"
echo ""

CLASSID_COUNTER=10
CYCLE_COUNT=0
CURRENT_TIME=0
SCRIPT_STARTED_AT=$(date +%s)
LAST_UDP_HEARTBEAT=""
UDP_WATCHDOG_ARMED=0
UDP_EMPTY_CYCLES=0

while true; do
    CYCLE_COUNT=$((CYCLE_COUNT + 1))
    CURRENT_TIME=$(date +%s)

    if ! kill -0 "$UDP_LISTENER_PID" 2>/dev/null; then
        request_restart "UDP listener неожиданно завершился"
    fi

    if [ $((CURRENT_TIME - SCRIPT_STARTED_AT)) -ge "$MAX_RUNTIME_SECONDS" ]; then
        request_restart "Достигнут лимит непрерывной работы (${MAX_RUNTIME_SECONDS}s)"
    fi

    CURRENT_UDP_HEARTBEAT=$(<"$UDP_HEARTBEAT_FILE")
    if [ -n "$CURRENT_UDP_HEARTBEAT" ] && [ "$CURRENT_UDP_HEARTBEAT" != "$LAST_UDP_HEARTBEAT" ]; then
        LAST_UDP_HEARTBEAT=$CURRENT_UDP_HEARTBEAT
        UDP_WATCHDOG_ARMED=1
        UDP_EMPTY_CYCLES=0
        reset_empty_udp_restart_latch
    elif [ "$UDP_WATCHDOG_ARMED" -eq 1 ]; then
        if [ "$EMPTY_UDP_RESTART_LATCHED" -eq 1 ]; then
            UDP_EMPTY_CYCLES=0
            debug_log "Нет новых валидных UDP-отчётов, повторный быстрый рестарт уже выполнен"
        else
            UDP_EMPTY_CYCLES=$((UDP_EMPTY_CYCLES + 1))
            debug_log "Нет новых валидных UDP-отчётов: $UDP_EMPTY_CYCLES/$WATCHDOG_MAX_EMPTY_CYCLES"

            if [ "$UDP_EMPTY_CYCLES" -ge "$WATCHDOG_MAX_EMPTY_CYCLES" ]; then
                if latch_empty_udp_restart; then
                    request_restart "Не получены IP клиентов в $UDP_EMPTY_CYCLES последовательных циклах"
                fi

                error_log "Быстрый рестарт пропущен: marker состояния не удалось сохранить"
            fi
        fi
    fi
    
    debug_log "=== Цикл #$CYCLE_COUNT ==="
    
    CLIENT_PINGS=$(get_client_pings)
    
    if [ -n "$CLIENT_PINGS" ]; then
        while IFS='|' read -r REPORT_PING_PORT CLIENT_IP CLIENT_PING CLIENT_SET; do
            [ -z "$CLIENT_IP" ] && continue
            
            for PORT in "${!PORT_DELAYS[@]}"; do
                [ "${PORT_PING_PORTS[$PORT]}" != "$REPORT_PING_PORT" ] && continue

                key="$PORT|$CLIENT_IP"
                
                CLIENT_SET=${CLIENT_SET:-0}
                KEY_CUSTOM_TARGET[$key]=$CLIENT_SET
                
                delay_changed_at=${KEY_DELAY_CHANGED_AT[$key]:-0}
                if [ "$delay_changed_at" -gt 0 ]; then
                    time_since_change=$((CURRENT_TIME - delay_changed_at))
                    if [ "$time_since_change" -lt "$DELAY_SETTLE_TIME" ]; then
                        debug_log "  $key: игнорируем замер (${time_since_change}s < ${DELAY_SETTLE_TIME}s после изменения)"
                        KEY_LAST_SEEN[$key]=$CURRENT_TIME
                        continue
                    fi
                fi
                
                KEY_CURRENT_PING[$key]=$CLIENT_PING
                KEY_LAST_SEEN[$key]=$CURRENT_TIME
                
                add_ping_to_history "$key" "$CLIENT_PING"
            done
        done <<< "$CLIENT_PINGS"
    fi
    
    for PORT in "${!PORT_DELAYS[@]}"; do
        DEFAULT_MIN_PING=${PORT_DELAYS[$PORT]}
        
        if ! CONNTRACK_OUTPUT=$(conntrack -L -p udp --dport "$PORT" 2>/dev/null); then
            request_restart "Не удалось получить conntrack-соединения для порта $PORT"
        fi

        ACTIVE_CLIENTS=$(awk '{
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^src=/) {
                    sub(/^src=/, "", $i)
                    print $i
                    break
                }
            }
        }' <<< "$CONNTRACK_OUTPUT" | sort -u)

        if [ -n "$ACTIVE_CLIENTS" ]; then
            UDP_WATCHDOG_ARMED=1
        fi
        
        for key in "${!KEY_LAST_SEEN[@]}"; do
            [[ "$key" != "$PORT|"* ]] && continue
            ip="${key#"$PORT|"}"
            
            last_seen=${KEY_LAST_SEEN[$key]:-0}
            age=$((CURRENT_TIME - last_seen))
            
            if [ "$age" -gt "$CLIENT_TIMEOUT" ]; then
                remove_client_completely "$PORT" "$ip"
            fi
        done
        
        if [ -z "$ACTIVE_CLIENTS" ]; then
            debug_log "Нет активных клиентов на порту $PORT"
            continue
        fi
        
        for CLIENT_IP in $ACTIVE_CLIENTS; do
            key="$PORT|$CLIENT_IP"
            
            if handle_custom_target_change "$PORT" "$CLIENT_IP"; then
                continue
            fi
            
            delay_changed_at=${KEY_DELAY_CHANGED_AT[$key]:-0}
            if [ "$delay_changed_at" -gt 0 ]; then
                time_since_change=$((CURRENT_TIME - delay_changed_at))
                if [ "$time_since_change" -lt "$DELAY_SETTLE_TIME" ]; then
                    debug_log "  $key: ожидание стабилизации netem (${time_since_change}s/${DELAY_SETTLE_TIME}s)"
                    continue
                fi
            fi
            
            history_count=$(get_history_count "$key")
            if [ "$history_count" -lt "$MIN_SAMPLES_BEFORE_ACTION" ]; then
                debug_log "  $key: накопление замеров ($history_count/$MIN_SAMPLES_BEFORE_ACTION)..."
                continue
            fi
            
            stable_counter=${KEY_STABLE_COUNTER[$key]:-0}
            if [ "$stable_counter" -gt 0 ]; then
                KEY_STABLE_COUNTER[$key]=$((stable_counter - 1))
                debug_log "  $key: период стабилизации (осталось ${KEY_STABLE_COUNTER[$key]} циклов)"
                continue
            fi
            
            AVG_PING=$(calculate_average_ping "${KEY_PING_HISTORY[$key]}")
            
            if [ "$AVG_PING" -le 0 ]; then
                debug_log "  $key: некорректный средний пинг ($AVG_PING)"
                continue
            fi
            
            TARGET_PING=$(get_effective_target "$PORT" "$CLIENT_IP")
            CUSTOM_TARGET=${KEY_CUSTOM_TARGET[$key]:-0}
            ADDED_DELAY=${KEY_ADDED_DELAY[$key]:-0}
            
            BASE_PING=$((AVG_PING - ADDED_DELAY))
            if [ "$BASE_PING" -lt 1 ]; then
                BASE_PING=1
            fi
            KEY_BASE_PING[$key]=$BASE_PING
            
            NEEDED_DELAY=$((TARGET_PING - BASE_PING))
            if [ "$NEEDED_DELAY" -lt 0 ]; then
                NEEDED_DELAY=0
            fi
            
            if [ "$CUSTOM_TARGET" -gt 0 ] && [ "$CUSTOM_TARGET" -gt "$DEFAULT_MIN_PING" ]; then
                TARGET_SOURCE="custom"
            else
                TARGET_SOURCE="global"
            fi
            
            if [ "$BASE_PING" -ge $((TARGET_PING + UPPER_HYSTERESIS)) ]; then
                if [ "$ADDED_DELAY" -gt 0 ]; then
                    info_log "→ $key: base=${BASE_PING}ms >= target+${UPPER_HYSTERESIS}=$((TARGET_PING + UPPER_HYSTERESIS))ms, убираем задержку"
                    if ! set_delay_for_key "$PORT" "$CLIENT_IP" 0 "${KEY_CLASSID[$key]:-$CLASSID_COUNTER}"; then
                        request_restart "Не удалось удалить TC-правило для $key"
                    fi
                fi
                continue
            fi
            
            if [ "$BASE_PING" -lt "$TARGET_PING" ]; then
                DIFF=$((NEEDED_DELAY - ADDED_DELAY))
                
                if [ "$DIFF" -gt 0 ]; then
                    if [ "$DIFF" -lt "$MIN_DELAY_INCREASE" ]; then
                        debug_log "  $key: увеличение ${DIFF}ms < ${MIN_DELAY_INCREASE}ms, пропускаем"
                        continue
                    fi
                elif [ "$DIFF" -lt 0 ]; then
                    DIFF_ABS=$(( -DIFF ))
                    if [ "$DIFF_ABS" -lt "$MIN_DELAY_DECREASE" ]; then
                        debug_log "  $key: уменьшение ${DIFF_ABS}ms < ${MIN_DELAY_DECREASE}ms, пропускаем"
                        continue
                    fi
                else
                    debug_log "  $key: delay уже оптимален (${ADDED_DELAY}ms)"
                    continue
                fi
                
                allocate_classid_for_key "$key"
                
                info_log "→ $key: avg=${AVG_PING}ms, base=${BASE_PING}ms, target=${TARGET_PING}ms($TARGET_SOURCE), delay: ${ADDED_DELAY}ms -> ${NEEDED_DELAY}ms"
                if ! set_delay_for_key "$PORT" "$CLIENT_IP" "$NEEDED_DELAY" "${KEY_CLASSID[$key]}"; then
                    request_restart "Не удалось обновить TC-правило для $key"
                fi
            else
                debug_log "  $key: base=${BASE_PING}ms в нейтральной зоне [${TARGET_PING}, $((TARGET_PING + UPPER_HYSTERESIS - 1))], delay=${ADDED_DELAY}ms"
            fi
        done
    done
    
    sleep 2
done
