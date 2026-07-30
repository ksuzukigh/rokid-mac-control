#!/system/bin/sh

HEARTBEAT_FILE="/data/local/tmp/rokid_mac_control_heartbeat"
PID_FILE="/data/local/tmp/rokid_mac_wifi_watchdog.pid"
LOG_FILE="/data/local/tmp/rokid_mac_wifi_watchdog.log"
MAX_HEARTBEAT_AGE="${1:-20}"
# Mac側が変更する前の「画面が消えるまでの時間」。空なら変更していない。
ORIGINAL_SCREEN_OFF_TIMEOUT="${2:-}"

# 画面休止防止のための定期的なキー送信はここでは行わない。
# 10秒ごとのKEYCODE_WAKEUPがBluetooth音声処理を起こし、
# 「ほわん」という音の原因になっていたため撤去した。
# 画面の休止防止は、Mac側がscreen_off_timeoutを一時的に伸ばすことで行う。

cleanup() {
    # Mac側が強制終了して復元できなかった場合に備え、端末側でも元へ戻す。
    # Mac側の正常終了時も呼ばれるが、同じ値を書くだけなので害はない。
    case "$ORIGINAL_SCREEN_OFF_TIMEOUT" in
        ''|*[!0-9]*) ;;
        *)
            settings put system screen_off_timeout \
                "$ORIGINAL_SCREEN_OFF_TIMEOUT" >/dev/null 2>&1
            printf '%s screen_off_timeout restored to %s\n' \
                "$(date '+%H:%M:%S')" "$ORIGINAL_SCREEN_OFF_TIMEOUT" \
                >> "$LOG_FILE"
            ;;
    esac
    # 自分が書いたPIDファイルのときだけ消す。次の監視スクリプトが
    # すでに起動している場合に、そちらの記録を消してしまわないため。
    if [ "$(cat "$PID_FILE" 2>/dev/null)" = "$$" ]; then
        rm -f "$PID_FILE"
    fi
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
