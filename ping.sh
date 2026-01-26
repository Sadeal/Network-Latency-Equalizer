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
# Ключи вида PORT|IP
declare -A KEY_CLASSID         # classid (число, без 1:)
declare -A KEY_CURRENT_PING    # текущий пинг (уже с учётом netem)
declare -A KEY_ADDED_DELAY     # сколько ms netem сейчас добавляет
declare -A KEY_HAS_RULE        # есть ли netem для этого key
declare -A KEY_LAST_SEEN       # timestamp последней активности клиента
declare -A KEY_PING_HISTORY    # история пингов для сглаживания (через запятую)
declare -A KEY_BASE_PING       # базовый (реальный) пинг клиента без netem
declare -A KEY_STABLE_COUNTER  # Счётчик циклов стабилизации
declare -A KEY_DELAY_CHANGED_AT # Timestamp последнего изменения задержки

# Параметры стабилизации
HYSTERESIS=3                   # Гистерезис в ms для предотвращения осцилляций
PING_SAMPLES=5                 # Количество замеров для усреднения
MIN_SAMPLES_BEFORE_ACTION=3    # Минимум замеров ПОСЛЕ изменения задержки
CLIENT_TIMEOUT=30              # Таймаут неактивности клиента в секундах
MIN_DELAY_CHANGE=2             # Минимальное изменение задержки для применения
STABILIZATION_CYCLES=5         # Циклов стабилизации после изменения (увеличено с 3)
DELAY_SETTLE_TIME=4            # Секунд ожидания после изменения задержки

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
FIRST_PING_PORT=${PORT_PING_PORTS[${!PORT_PING_PORTS[@]}]}
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
            if [[ "$line" =~ ([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})\|([0-9]+) ]]; then
                client_ip="${BASH_REMATCH[1]}"
                ping_value="${BASH_REMATCH[2]}"
                if [[ "$client_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                    echo "$(date +%s)|$client_ip|$ping_value" >> "$UDP_DATA_FILE"
                    debug_log "UDP Packet: $client_ip -> ${ping_value}ms"
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
    if [ ! -s "$UDP_DATA_FILE" ]; then
        return
    fi
    while IFS='|' read -r timestamp client_ip ping_value; do
        if [ -n "$timestamp" ] && [ -n "$client_ip" ] && [ -n "$ping_value" ]; then
            local age=$((current_time - timestamp))
            if [ $age -le $max_age ]; then
                latest_pings["$client_ip"]=$ping_value
            fi
        fi
    done < "$UDP_DATA_FILE"
    if [ "$(wc -l < "$UDP_DATA_FILE")" -gt 100 ]; then
        tail -100 "$UDP_DATA_FILE" > "${UDP_DATA_FILE}.tmp"
        mv "${UDP_DATA_FILE}.tmp" "$UDP_DATA_FILE"
    fi
    for ip in "${!latest_pings[@]}"; do
        echo "$ip|${latest_pings[$ip]}"
    done
}
# Функция для вычисления среднего пинга из истории
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
# Функция для добавления пинга в историю (FIFO)
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
            # Удаляем первый элемент, добавляем новый в конец
            pings=("${pings[@]:1}")
        fi

        pings+=("$ping")
        KEY_PING_HISTORY[$key]=$(IFS=','; echo "${pings[*]}")
    fi
}
# Функция для получения количества замеров в истории
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

# НОВОЕ: Функция очистки истории пингов
clear_ping_history() {
    local key=$1
    KEY_PING_HISTORY[$key]=""
    debug_log "  $key: история пингов очищена"
}

# === TC (HTB) ===
TC_RATE="1000mbit"
set_delay_for_key() {
    local port=$1
    local ip=$2
    local delay=$3
    local classid=$4
    local key="$port|$ip"
    local current_time=$(date +%s)

    # delay <= 0: удаляем правила
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
        
        # НОВОЕ: Очищаем историю и устанавливаем время изменения
        clear_ping_history "$key"
        KEY_DELAY_CHANGED_AT[$key]=$current_time
        KEY_STABLE_COUNTER[$key]=$STABILIZATION_CYCLES
        
        info_log "✗ УБРАНО: $key | задержка больше не нужна"
        return
    fi
    # Если класс уже был — удаляем старые сущности
    if [ -n "${KEY_CLASSID[$key]}" ] && [ "${KEY_HAS_RULE[$key]}" == "1" ]; then
        local old_classid="${KEY_CLASSID[$key]}"
        tc filter del dev "$INTERFACE" parent 1: protocol ip prio "$old_classid" u32 2>/dev/null
        tc qdisc del dev "$INTERFACE" parent 1:"$old_classid" 2>/dev/null
        tc class del dev "$INTERFACE" classid 1:"$old_classid" 2>/dev/null
    fi
    # Создаём новый класс/очередь/фильтр
    tc class add dev "$INTERFACE" parent 1: classid 1:"$classid" htb rate "$TC_RATE" ceil "$TC_RATE" 2>/dev/null
    tc qdisc add dev "$INTERFACE" parent 1:"$classid" handle "${classid}0:" netem delay "${delay}ms" 2>/dev/null
    tc filter add dev "$INTERFACE" parent 1: protocol ip prio "$classid" u32 \
        match ip dst "$ip" \
        flowid 1:"$classid" 2>/dev/null
    KEY_CLASSID[$key]=$classid
    KEY_ADDED_DELAY[$key]=$delay
    KEY_HAS_RULE[$key]=1
    
    # НОВОЕ: Очищаем историю пингов - старые значения больше не актуальны!
    clear_ping_history "$key"
    KEY_DELAY_CHANGED_AT[$key]=$current_time
    KEY_STABLE_COUNTER[$key]=$STABILIZATION_CYCLES
    
    info_log "✓ УСТАНОВЛЕНО: $key | Добавлено: ${delay}ms (история очищена, ждём стабилизации)"
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
    info_log "✗ ОТКЛЮЧИЛСЯ: $key | Правила удалены (таймаут)"
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
info_log "Параметры: гистерезис=${HYSTERESIS}ms, сглаживание=${PING_SAMPLES} замеров, таймаут=${CLIENT_TIMEOUT}s"
info_log "Стабилизация: ${STABILIZATION_CYCLES} циклов, мин. замеров=${MIN_SAMPLES_BEFORE_ACTION}, settle=${DELAY_SETTLE_TIME}s"
info_log "Для остановки нажмите Ctrl+C"
echo ""
CLASSID_COUNTER=10
CYCLE_COUNT=0
CURRENT_TIME=0
while true; do
    CYCLE_COUNT=$((CYCLE_COUNT + 1))
    CURRENT_TIME=$(date +%s)
    debug_log "=== Цикл #$CYCLE_COUNT ==="
    # Получаем свежие данные о пингах
    CLIENT_PINGS=$(get_client_pings)
    if [ -n "$CLIENT_PINGS" ]; then
        while IFS='|' read -r CLIENT_IP CLIENT_PING; do
            [ -z "$CLIENT_IP" ] && continue
            for PORT in "${!PORT_DELAYS[@]}"; do
                key="$PORT|$CLIENT_IP"
                
                # НОВОЕ: Проверяем, не слишком ли рано после изменения задержки
                # Игнорируем замеры в первые DELAY_SETTLE_TIME секунд после изменения
                if [ -n "${KEY_DELAY_CHANGED_AT[$key]}" ]; then
                    local time_since_change=$((CURRENT_TIME - KEY_DELAY_CHANGED_AT[$key]))
                    if [ $time_since_change -lt $DELAY_SETTLE_TIME ]; then
                        debug_log "  $key: игнорируем замер (${time_since_change}s < ${DELAY_SETTLE_TIME}s после изменения)"
                        KEY_LAST_SEEN[$key]=$CURRENT_TIME
                        continue
                    fi
                fi
                
                KEY_CURRENT_PING[$key]=$CLIENT_PING
                KEY_LAST_SEEN[$key]=$CURRENT_TIME

                # Добавляем в историю для сглаживания
                add_ping_to_history "$key" "$CLIENT_PING"
            done
        done <<< "$CLIENT_PINGS"
    fi
    for PORT in "${!PORT_DELAYS[@]}"; do
        TARGET_PING=${PORT_DELAYS[$PORT]}
        # Получаем активных клиентов из conntrack
        ACTIVE_CLIENTS=$(conntrack -L -p udp --dport "$PORT" 2>/dev/null | grep -oP 'src=\K[0-9.]+' | sort -u)
        declare -A ACTIVE_SET=()
        for ip in $ACTIVE_CLIENTS; do
            ACTIVE_SET["$ip"]=1
        done
        # Проверяем таймауты клиентов (НЕ по conntrack, а по времени последнего пинга)
        for key in "${!KEY_LAST_SEEN[@]}"; do
            [[ "$key" != "$PORT|"* ]] && continue
            ip="${key#"$PORT|"}"

            last_seen=${KEY_LAST_SEEN[$key]}
            age=$((CURRENT_TIME - last_seen))

            # Удаляем только если клиент не отвечал дольше CLIENT_TIMEOUT
            if [ $age -gt $CLIENT_TIMEOUT ]; then
                remove_client_completely "$PORT" "$ip"
            fi
        done
        if [ -z "$ACTIVE_CLIENTS" ]; then
            debug_log "Нет активных клиентов на порту $PORT"
            continue
        fi
        for CLIENT_IP in $ACTIVE_CLIENTS; do
            key="$PORT|$CLIENT_IP"

            # НОВОЕ: Проверяем время после изменения задержки
            if [ -n "${KEY_DELAY_CHANGED_AT[$key]}" ]; then
                local time_since_change=$((CURRENT_TIME - KEY_DELAY_CHANGED_AT[$key]))
                if [ $time_since_change -lt $DELAY_SETTLE_TIME ]; then
                    debug_log "  $key: ожидание стабилизации netem (${time_since_change}s/${DELAY_SETTLE_TIME}s)"
                    continue
                fi
            fi

            # Ждём минимум MIN_SAMPLES_BEFORE_ACTION замеров для начала работы
            history_count=$(get_history_count "$key")
            if [ "$history_count" -lt $MIN_SAMPLES_BEFORE_ACTION ]; then
                debug_log "  $key: накопление замеров ($history_count/$MIN_SAMPLES_BEFORE_ACTION)..."
                continue
            fi
            # Если идёт стабилизация — пропускаем
            if [ -n "${KEY_STABLE_COUNTER[$key]}" ] && [ "${KEY_STABLE_COUNTER[$key]}" -gt 0 ]; then
                KEY_STABLE_COUNTER[$key]=$((KEY_STABLE_COUNTER[$key] - 1))
                debug_log "  $key: период стабилизации (осталось ${KEY_STABLE_COUNTER[$key]} циклов)"
                continue
            fi
            # Вычисляем средний пинг из истории
            AVG_PING=$(calculate_average_ping "${KEY_PING_HISTORY[$key]}")

            if [ "$AVG_PING" -le 0 ]; then
                debug_log "  $key: некорректный средний пинг ($AVG_PING)"
                continue
            fi
            ADDED_DELAY=${KEY_ADDED_DELAY[$key]:-0}
            # Вычисляем базовый (реальный) пинг без netem
            # ВАЖНО: netem добавляет задержку в одну сторону,
            # но пинг = RTT, поэтому влияние netem на пинг = ADDED_DELAY
            BASE_PING=$((AVG_PING - ADDED_DELAY))

            # Защита от отрицательного значения
            if [ "$BASE_PING" -lt 1 ]; then
                BASE_PING=1
            fi

            # Сохраняем базовый пинг для информации
            KEY_BASE_PING[$key]=$BASE_PING
            # === ЛОГИКА С ГИСТЕРЕЗИСОМ ===

            # Целевая задержка для достижения TARGET_PING
            NEEDED_DELAY=$((TARGET_PING - BASE_PING))

            # Защита от отрицательной задержки
            if [ "$NEEDED_DELAY" -lt 0 ]; then
                NEEDED_DELAY=0
            fi
            # Текущий эффективный пинг (как его видит клиент)
            EFFECTIVE_PING=$((BASE_PING + ADDED_DELAY))
            # Условие для УБИРАНИЯ задержки (с гистерезисом вверх):
            # Убираем только если базовый пинг ВЫШЕ target + гистерезис
            if [ "$BASE_PING" -ge $((TARGET_PING + HYSTERESIS)) ]; then
                if [ "$ADDED_DELAY" -gt 0 ]; then
                    info_log "→ $key: base=${BASE_PING}ms >= target+hyst=$((TARGET_PING + HYSTERESIS))ms, убираем задержку"
                    set_delay_for_key "$PORT" "$CLIENT_IP" 0 "${KEY_CLASSID[$key]:-$CLASSID_COUNTER}"
                fi
                continue
            fi
            # Условие для ДОБАВЛЕНИЯ/ИЗМЕНЕНИЯ задержки:
            # Добавляем если базовый пинг ниже target - гистерезис
            if [ "$BASE_PING" -lt $((TARGET_PING - HYSTERESIS)) ]; then

                # Проверяем минимальное изменение
                DIFF=$((NEEDED_DELAY - ADDED_DELAY))
                [ $DIFF -lt 0 ] && DIFF=$(( -DIFF ))
                if [ "$DIFF" -lt $MIN_DELAY_CHANGE ]; then
                    debug_log "  $key: изменение ${DIFF}ms < ${MIN_DELAY_CHANGE}ms, пропускаем"
                    continue
                fi
                # Назначаем classid если нет
                if [ -z "${KEY_CLASSID[$key]}" ]; then
                    KEY_CLASSID[$key]=$CLASSID_COUNTER
                    CLASSID_COUNTER=$((CLASSID_COUNTER + 1))
                    if [ $CLASSID_COUNTER -gt 65000 ]; then
                        error_log "Достигнут лимит classid (65000). Перезапустите скрипт."
                        exit 1
                    fi
                fi
                info_log "→ $key: avg=${AVG_PING}ms, base=${BASE_PING}ms, target=${TARGET_PING}ms, old_delay=${ADDED_DELAY}ms, new_delay=${NEEDED_DELAY}ms"
                set_delay_for_key "$PORT" "$CLIENT_IP" "$NEEDED_DELAY" "${KEY_CLASSID[$key]}"

            else
                # Базовый пинг в "зоне гистерезиса" — ничего не меняем
                debug_log "  $key: base=${BASE_PING}ms в зоне гистерезиса [${TARGET_PING}-${HYSTERESIS}, ${TARGET_PING}+${HYSTERESIS}], сохраняем delay=${ADDED_DELAY}ms"
            fi
        done

        unset ACTIVE_SET
    done
    sleep 2
done
