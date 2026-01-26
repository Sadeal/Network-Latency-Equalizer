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
if [ $# -lt 3 ] || [ $((($# % 3))) -ne 0 ]; then
    error_log "Неправильные аргументы"
    echo "Использование: $0 PORT1 PING_PORT1 MIN_PING1 PORT2 PING_PORT2 MIN_PING2 ..."
    echo "Пример: $0 27055 27056 30"
    exit 1
fi
detect_interface() {
    local iface
    iface=$(ip route | awk '/default/ {print $5}' | head -1)
    if [ -z "$iface" ]; then
        iface=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $5; exit}')
    fi
    echo "$iface"
}
get_interface_ip() {
    local iface=$1
    local ip
    ip=$(ip -4 addr show "$iface" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    echo "$ip"
}
INTERFACE=$(detect_interface)
SERVER_IP=$(get_interface_ip "$INTERFACE")
info_log "Интерфейс: $INTERFACE, IP: $SERVER_IP"
if ! command -v conntrack &> /dev/null; then
    error_log "conntrack не установлен. Установите: apt-get install conntrack"
    exit 1
fi
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

HYSTERESIS=3
PING_SAMPLES=5
MIN_SAMPLES_BEFORE_ACTION=3
CLIENT_TIMEOUT=30
MIN_DELAY_CHANGE=2
STABILIZATION_CYCLES=5
DELAY_SETTLE_TIME=4

TC_INITIALIZED=0
UDP_LISTENER_PID=0
UDP_DATA_FILE="/tmp/ping_udp_data_$$"
> "$UDP_DATA_FILE"
cleanup() {
    echo ""
    info_log "=== Завершение работы ==="
    if [ $UDP_LISTENER_PID -ne 0 ]; then
        kill -9 $UDP_LISTENER_PID 2>/dev/null
    fi
    rm -f "$UDP_DATA_FILE"
    if [ $TC_INITIALIZED -eq 1 ]; then
        tc qdisc del dev "$INTERFACE" root 2>/dev/null
        info_log "TC правила удалены"
    fi
    exit 0
}
trap cleanup EXIT SIGINT SIGTERM
TEMP_ARGS=("$@")
while [ ${#TEMP_ARGS[@]} -gt 0 ]; do
    PORT=${TEMP_ARGS[0]}
    PING_PORT=${TEMP_ARGS[1]}
    MIN_PING=${TEMP_ARGS[2]}
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
        tcpdump -i any -n -l -A "$final_filter" 2>/dev/null | \
        while read -r line; do
            if [[ "$line" =~ ([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})\|([0-9]+)\|([0-9]+) ]]; then
                client_ip="${BASH_REMATCH[1]}"
                ping_value="${BASH_REMATCH[2]}"
                set_value="${BASH_REMATCH[3]}"
                if [[ "$client_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                    echo "$(date +%s)|$client_ip|$ping_value|$set_value" >> "$UDP_DATA_FILE"
                    debug_log "UDP Packet: $client_ip -> ping=${ping_value}ms, set=${set_value}ms"
                fi
            elif [[ "$line" =~ ([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})\|([0-9]+) ]]; then
                client_ip="${BASH_REMATCH[1]}"
                ping_value="${BASH_REMATCH[2]}"
                if [[ "$client_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                    echo "$(date +%s)|$client_ip|$ping_value|0" >> "$UDP_DATA_FILE"
                    debug_log "UDP Packet (legacy): $client_ip -> ping=${ping_value}ms, set=0"
                fi
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
    while IFS='|' read -r timestamp client_ip ping_value set_value; do
        if [ -n "$timestamp" ] && [ -n "$client_ip" ] && [ -n "$ping_value" ]; then
            local age=$((current_time - timestamp))
            if [ $age -le $max_age ]; then
                latest_pings["$client_ip"]=$ping_value
                latest_sets["$client_ip"]=${set_value:-0}
            fi
        fi
    done < "$UDP_DATA_FILE"
    if [ "$(wc -l < "$UDP_DATA_FILE")" -gt 100 ]; then
        tail -100 "$UDP_DATA_FILE" > "${UDP_DATA_FILE}.tmp"
        mv "${UDP_DATA_FILE}.tmp" "$UDP_DATA_FILE"
    fi
    for ip in "${!latest_pings[@]}"; do
        echo "$ip|${latest_pings[$ip]}|${latest_sets[$ip]}"
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
set_delay_for_key() {
    local port=$1
    local ip=$2
    local delay=$3
    local classid=$4
    local key="$port|$ip"
    local current_time=$(date +%s)
    if [ "$delay" -le 0 ]; then
        debug_log "  $key: delay <= 0, убираем netem"
        if [ -n "${KEY_CLASSID[$key]}" ]; then
            local old_classid="${KEY_CLASSID[$key]}"
            tc filter del dev "$INTERFACE" parent 1: protocol ip prio "$old_classid" u32 2>/dev/null
            tc qdisc del dev "$INTERFACE" parent 1:"$old_classid" 2>/dev/null
            tc class del dev "$INTERFACE" classid 1:"$old_classid" 2>/dev/null
        fi
        KEY_ADDED_DELAY[$key]=0
        KEY_HAS_RULE[$key]=0
        clear_ping_history "$key"
        KEY_DELAY_CHANGED_AT[$key]=$current_time
        KEY_STABLE_COUNTER[$key]=$STABILIZATION_CYCLES
        info_log "✗ УБРАНО: $key | задержка больше не нужна"
        return
    fi
    if [ -n "${KEY_CLASSID[$key]}" ] && [ "${KEY_HAS_RULE[$key]}" == "1" ]; then
        local old_classid="${KEY_CLASSID[$key]}"
        tc filter del dev "$INTERFACE" parent 1: protocol ip prio "$old_classid" u32 2>/dev/null
        tc qdisc del dev "$INTERFACE" parent 1:"$old_classid" 2>/dev/null
        tc class del dev "$INTERFACE" classid 1:"$old_classid" 2>/dev/null
    fi
    tc class add dev "$INTERFACE" parent 1: classid 1:"$classid" htb rate "$TC_RATE" ceil "$TC_RATE" 2>/dev/null
    tc qdisc add dev "$INTERFACE" parent 1:"$classid" handle "${classid}0:" netem delay "${delay}ms" 2>/dev/null
    tc filter add dev "$INTERFACE" parent 1: protocol ip prio "$classid" u32 \
        match ip dst "$ip" \
        flowid 1:"$classid" 2>/dev/null
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
        tc filter del dev "$INTERFACE" parent 1: protocol ip prio "$classid" u32 2>/dev/null
        tc qdisc del dev "$INTERFACE" parent 1:"$classid" 2>/dev/null
        tc class del dev "$INTERFACE" classid 1:"$classid" 2>/dev/null
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
    if [ -z "${KEY_CLASSID[$key]}" ]; then
        KEY_CLASSID[$key]=$CLASSID_COUNTER
        CLASSID_COUNTER=$((CLASSID_COUNTER + 1))
    fi
    info_log "  → Пересчёт: base=${base_ping}ms, target=${effective_target}ms, delay: ${added_delay}ms -> ${needed_delay}ms"
    set_delay_for_key "$port" "$client_ip" "$needed_delay" "${KEY_CLASSID[$key]}"
    return 0
}
info_log "=== Инициализация TC ==="
tc qdisc del dev "$INTERFACE" root 2>/dev/null
tc qdisc add dev "$INTERFACE" root handle 1: htb default 1
if [ $? -ne 0 ]; then
    error_log "Ошибка TC: не удалось добавить root htb"
    exit 1
fi
tc class add dev "$INTERFACE" parent 1: classid 1:1 htb rate "$TC_RATE" ceil "$TC_RATE" 2>/dev/null
TC_INITIALIZED=1
info_log "TC (HTB) инициализирован успешно"
ALL_PING_PORTS=""
for p in "${PORT_PING_PORTS[@]}"; do
    ALL_PING_PORTS="$ALL_PING_PORTS $p"
done
start_udp_listener "$SERVER_IP" "$ALL_PING_PORTS"
sleep 2
if ! ps -p $UDP_LISTENER_PID > /dev/null 2>&1; then
    error_log "UDP listener не запустился! Проверьте tcpdump."
    exit 1
fi
echo ""
info_log "=== Скрипт запущен ==="
info_log "Мониторинг портов: ${!PORT_DELAYS[@]}"
info_log "UDP Listener работает на $SERVER_IP"
info_log "Формат пакетов: ip|ping|set (set=0 -> MIN_PING, set>MIN_PING -> индивидуальный)"
info_log "Для остановки нажмите Ctrl+C"
echo ""
CLASSID_COUNTER=10
CYCLE_COUNT=0
CURRENT_TIME=0
while true; do
    CYCLE_COUNT=$((CYCLE_COUNT + 1))
    CURRENT_TIME=$(date +%s)
    debug_log "=== Цикл #$CYCLE_COUNT ==="
    CLIENT_PINGS=$(get_client_pings)
    if [ -n "$CLIENT_PINGS" ]; then
        while IFS='|' read -r CLIENT_IP CLIENT_PING CLIENT_SET; do
            [ -z "$CLIENT_IP" ] && continue
            for PORT in "${!PORT_DELAYS[@]}"; do
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
        ACTIVE_CLIENTS=$(conntrack -L -p udp --dport "$PORT" 2>/dev/null | grep -oP 'src=\K[0-9.]+' | sort -u)
        declare -A ACTIVE_SET=()
        for ip in $ACTIVE_CLIENTS; do
            ACTIVE_SET["$ip"]=1
        done
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
            if [ "$BASE_PING" -ge $((TARGET_PING + HYSTERESIS)) ]; then
                if [ "$ADDED_DELAY" -gt 0 ]; then
                    info_log "→ $key: base=${BASE_PING}ms >= target($TARGET_SOURCE)+hyst=$((TARGET_PING + HYSTERESIS))ms, убираем задержку"
                    set_delay_for_key "$PORT" "$CLIENT_IP" 0 "${KEY_CLASSID[$key]:-$CLASSID_COUNTER}"
                fi
                continue
            fi
            if [ "$BASE_PING" -lt $((TARGET_PING - HYSTERESIS)) ]; then
                DIFF=$((NEEDED_DELAY - ADDED_DELAY))
                [ "$DIFF" -lt 0 ] && DIFF=$(( -DIFF ))
                if [ "$DIFF" -lt "$MIN_DELAY_CHANGE" ]; then
                    debug_log "  $key: изменение ${DIFF}ms < ${MIN_DELAY_CHANGE}ms, пропускаем"
                    continue
                fi
                if [ -z "${KEY_CLASSID[$key]}" ]; then
                    KEY_CLASSID[$key]=$CLASSID_COUNTER
                    CLASSID_COUNTER=$((CLASSID_COUNTER + 1))
                    if [ "$CLASSID_COUNTER" -gt 65000 ]; then
                        error_log "Достигнут лимит classid (65000). Перезапустите скрипт."
                        exit 1
                    fi
                fi
                info_log "→ $key: avg=${AVG_PING}ms, base=${BASE_PING}ms, target=${TARGET_PING}ms($TARGET_SOURCE), old_delay=${ADDED_DELAY}ms, new_delay=${NEEDED_DELAY}ms"
                set_delay_for_key "$PORT" "$CLIENT_IP" "$NEEDED_DELAY" "${KEY_CLASSID[$key]}"
            else
                debug_log "  $key: base=${BASE_PING}ms в зоне гистерезиса, сохраняем delay=${ADDED_DELAY}ms"
            fi
        done
        unset ACTIVE_SET
    done
    sleep 2
done
