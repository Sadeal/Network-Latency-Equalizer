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
    local port=$2

    info_log "Запуск UDP listener (tcpdump) на $ip:$port"

    (
        tcpdump -i any -n -l -A "udp port $port and dst host $ip" 2>/dev/null | \
        while read -r line; do
            if [[ "$line" =~ ([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})\|([0-9]+) ]]; then
                client_ip="${BASH_REMATCH[1]}"
                ping_value="${BASH_REMATCH[2]}"

                if [[ "$client_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                    echo "$(date +%s)|$client_ip|$ping_value" >> "$UDP_DATA_FILE"
                    debug_log "UDP: $client_ip -> ${ping_value}ms"
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

# === TC (HTB) ===
TC_RATE="1000mbit"

set_delay_for_key() {
    local port=$1
    local ip=$2
    local delay=$3
    local classid=$4
    local key="$port|$ip"

    # delay <= 0: удаляем правила
    if [ "$delay" -le 0 ]; then
        debug_log "  $key: delay <= 0, убираем netem"
        # если есть что удалять
        if [ -n "${KEY_CLASSID[$key]}" ]; then
            local old_classid="${KEY_CLASSID[$key]}"
            tc filter del dev "$INTERFACE" parent 1: protocol ip prio "$old_classid" u32 2>/dev/null
            tc qdisc del dev "$INTERFACE" parent 1:"$old_classid" 2>/dev/null
            tc class del dev "$INTERFACE" classid 1:"$old_classid" 2>/dev/null
        fi
        unset KEY_CLASSID[$key]
        unset KEY_ADDED_DELAY[$key]
        unset KEY_HAS_RULE[$key]
        info_log "✗ УБРАНО: $key | задержка больше не нужна"
        return
    fi

    # Если класс уже был — удаляем старые сущности
    if [ -n "${KEY_CLASSID[$key]}" ]; then
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

    info_log "✓ УСТАНОВЛЕНО: $key | Добавлено: ${delay}ms"
}

remove_delay_for_key() {
    local port=$1
    local ip=$2
    local key="$port|$ip"
    local classid="${KEY_CLASSID[$key]}"

    if [ -z "$classid" ]; then
        unset KEY_CURRENT_PING[$key]
        unset KEY_ADDED_DELAY[$key]
        unset KEY_HAS_RULE[$key]
        return
    fi

    tc filter del dev "$INTERFACE" parent 1: protocol ip prio "$classid" u32 2>/dev/null
    tc qdisc del dev "$INTERFACE" parent 1:"$classid" 2>/dev/null
    tc class del dev "$INTERFACE" classid 1:"$classid" 2>/dev/null

    unset KEY_CURRENT_PING[$key]
    unset KEY_ADDED_DELAY[$key]
    unset KEY_CLASSID[$key]
    unset KEY_HAS_RULE[$key]

    info_log "✗ ОТКЛЮЧИЛСЯ: $key | Правила удалены"
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

start_udp_listener "$SERVER_IP" "$FIRST_PING_PORT"
sleep 2

if ! ps -p $UDP_LISTENER_PID > /dev/null 2>&1; then
    error_log "UDP listener не запустился!"
    exit 1
fi

echo ""
info_log "=== Скрипт запущен ==="
info_log "Мониторинг портов: ${!PORT_DELAYS[@]}"
info_log "UDP Listener работает на $SERVER_IP:$FIRST_PING_PORT"
info_log "Логика: 1 замер → сразу применение; затем динамическая корректировка с порогом 2ms"
info_log "Для остановки нажмите Ctrl+C"
echo ""

CLASSID_COUNTER=10
CYCLE_COUNT=0

while true; do
    CYCLE_COUNT=$((CYCLE_COUNT + 1))
    debug_log "=== Цикл #$CYCLE_COUNT ==="

    CLIENT_PINGS=$(get_client_pings)
    if [ -n "$CLIENT_PINGS" ]; then
        while IFS='|' read -r CLIENT_IP CLIENT_PING; do
            [ -z "$CLIENT_IP" ] && continue
            for PORT in "${!PORT_DELAYS[@]}"; do
                key="$PORT|$CLIENT_IP"
                KEY_CURRENT_PING[$key]=$CLIENT_PING
            done
        done <<< "$CLIENT_PINGS"
    fi

    for PORT in "${!PORT_DELAYS[@]}"; do
        TARGET_PING=${PORT_DELAYS[$PORT]}

        ACTIVE_CLIENTS=$(conntrack -L -p udp --dport "$PORT" 2>/dev/null | grep -oP 'src=\K[0-9.]+' | sort -u)

        declare -A ACTIVE_SET=()
        for ip in $ACTIVE_CLIENTS; do
            ACTIVE_SET["$ip"]=1
        done

        for key in "${!KEY_CLASSID[@]}"; do
            [[ "$key" != "$PORT|"* ]] && continue
            ip="${key#"$PORT|"}"
            if [ -z "${ACTIVE_SET[$ip]}" ]; then
                remove_delay_for_key "$PORT" "$ip"
            fi
        done

        if [ -z "$ACTIVE_CLIENTS" ]; then
            debug_log "Нет активных клиентов на порту $PORT"
            continue
        fi

        for CLIENT_IP in $ACTIVE_CLIENTS; do
            key="$PORT|$CLIENT_IP"

            if [ -z "${KEY_CURRENT_PING[$key]}" ]; then
                debug_log "  $key: ожидаем данные о пинге..."
                continue
            fi

            CLIENT_PING=${KEY_CURRENT_PING[$key]}
            ADDED_DELAY=${KEY_ADDED_DELAY[$key]:-0}

            if (( CYCLE_COUNT % 3 != 0 )); then
                debug_log "  $key: пропускаем пересчёт (цикл $CYCLE_COUNT)"
                continue
            fi

            # Реальный пинг без netem
            REAL_PING=$((CLIENT_PING - ADDED_DELAY))

            # Если без netem уже >= TARGET_PING → задержка не нужна
            if [ "$REAL_PING" -ge "$TARGET_PING" ]; then
                if [ "$ADDED_DELAY" -gt 0 ]; then
                    debug_log "  $key: real ${REAL_PING}ms >= target ${TARGET_PING}ms, убираем netem"
                    set_delay_for_key "$PORT" "$CLIENT_IP" 0 "${KEY_CLASSID[$key]}"
                else
                    debug_log "  $key: real ${REAL_PING}ms >= target, ничего не делаем"
                fi
                continue
            fi

            # Нужная задержка, чтобы стало ровно TARGET_PING:
            # D_new = TARGET_PING - REAL_PING
            NEEDED_DELAY=$((TARGET_PING - REAL_PING))

            # Порог чувствительности: если разница < 2ms && NEEDED_DELAY > 10 || < 1ms && NEEDED_DELAY <= 10 — не трогаем
            DIFF=$((NEEDED_DELAY - ADDED_DELAY))
            [ $DIFF -lt 0 ] && DIFF=$(( -DIFF ))

            if [ "$NEEDED_DELAY" -gt 10 ]; then
                THRESHOLD=2
            else
                THRESHOLD=1
            fi

            if [ "$DIFF" -lt "$THRESHOLD" ]; then
                debug_log "  $key: нужно ${NEEDED_DELAY}ms, сейчас ${ADDED_DELAY}ms, diff=${DIFF}ms < ${THRESHOLD}ms, не трогаем"
                continue
            fi

            # Назначаем/переназначаем задержку
            if [ -z "${KEY_CLASSID[$key]}" ]; then
                KEY_CLASSID[$key]=$CLASSID_COUNTER
                classid=$CLASSID_COUNTER
                CLASSID_COUNTER=$((CLASSID_COUNTER + 1))
                if [ $CLASSID_COUNTER -gt 65000 ]; then
                    error_log "Достигнут лимит classid (65000). Перезапусти скрипт."
                    exit 1
                fi
            else
                classid=${KEY_CLASSID[$key]}
            fi

            info_log "→ $key: real=${REAL_PING}ms, target=${TARGET_PING}ms, old=${ADDED_DELAY}ms, new=${NEEDED_DELAY}ms"
            set_delay_for_key "$PORT" "$CLIENT_IP" "$NEEDED_DELAY" "$classid"
        done
    done

    sleep 2
done
