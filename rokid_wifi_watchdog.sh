#!/system/bin/sh

HEARTBEAT_FILE="/data/local/tmp/rokid_mac_control_heartbeat"
PID_FILE="/data/local/tmp/rokid_mac_wifi_watchdog.pid"
LOG_FILE="/data/local/tmp/rokid_mac_wifi_watchdog.log"
MAX_HEARTBEAT_AGE="${1:-20}"

cleanup() {
    rm -f "$PID_FILE"
}
trap cleanup EXIT
trap 'exit 0' HUP INT TERM

printf '%s\n' "$$" > "$PID_FILE"
printf '%s watchdog started\n' "$(date '+%H:%M:%S')" > "$LOG_FILE"

while true; do
    if [ ! -f "$HEARTBEAT_FILE" ]; then
        printf '%s heartbeat missing; watchdog stopped\n' "$(date '+%H:%M:%S')" >> "$LOG_FILE"
        exit 0
    fi

    now_epoch="$(date '+%s')"
    heartbeat_epoch="$(stat -c '%Y' "$HEARTBEAT_FILE" 2>/dev/null)"
    case "$now_epoch:$heartbeat_epoch" in
        *[!0-9:]*|:*)
            printf '%s heartbeat unreadable; watchdog stopped\n' "$(date '+%H:%M:%S')" >> "$LOG_FILE"
            exit 0
            ;;
    esac

    heartbeat_age=$((now_epoch - heartbeat_epoch))
    if [ "$heartbeat_age" -gt "$MAX_HEARTBEAT_AGE" ]; then
        printf '%s heartbeat expired; watchdog stopped\n' "$(date '+%H:%M:%S')" >> "$LOG_FILE"
        exit 0
    fi

    wifi_state="$(cmd wifi status 2>/dev/null | sed -n '1p')"
    if [ "$wifi_state" = "Wifi is disabled" ]; then
        printf '%s Wi-Fi disabled; enabling\n' "$(date '+%H:%M:%S')" >> "$LOG_FILE"
        cmd wifi set-wifi-enabled enabled >> "$LOG_FILE" 2>&1
        sleep 2
    else
        sleep 1
    fi
done
