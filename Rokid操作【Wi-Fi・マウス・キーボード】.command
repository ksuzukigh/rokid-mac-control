#!/bin/bash

export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ADDRESS_FILE="$SCRIPT_DIR/.rokid_wifi_address"
PYTHON="$SCRIPT_DIR/.venv-rokid-keyboard/bin/python"
CONTROLLER="$SCRIPT_DIR/rokid_keyboard_control.py"
WATCHDOG_LOCAL="$SCRIPT_DIR/rokid_wifi_watchdog.sh"
CONTROLLER_PID=""
HEARTBEAT_PID=""
REMOTE_WATCHDOG="/data/local/tmp/rokid_wifi_watchdog.sh"
REMOTE_HEARTBEAT="/data/local/tmp/rokid_mac_control_heartbeat"
REMOTE_WATCHDOG_PID="/data/local/tmp/rokid_mac_wifi_watchdog.pid"
WATCHDOG_GRACE_SECONDS=20

pause_and_exit() {
    read -r -p "Enterキーで閉じます..."
    exit 1
}

connect_wifi() {
    adb connect "$1" >/dev/null 2>&1 &
    local connect_pid=$!
    local attempts=0

    while kill -0 "$connect_pid" >/dev/null 2>&1; do
        if [ "$attempts" -ge 20 ]; then
            kill "$connect_pid" >/dev/null 2>&1
            wait "$connect_pid" >/dev/null 2>&1
            return 1
        fi
        sleep 0.25
        attempts=$((attempts + 1))
    done

    wait "$connect_pid" >/dev/null 2>&1
}

heartbeat_loop() {
    local heartbeat_adb_pid=""
    trap 'if [ -n "$heartbeat_adb_pid" ]; then kill "$heartbeat_adb_pid" >/dev/null 2>&1; fi; exit 0' INT TERM

    while true; do
        adb -s "$ADDRESS" shell touch "$REMOTE_HEARTBEAT" >/dev/null 2>&1 &
        heartbeat_adb_pid=$!

        for heartbeat_attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
            if ! kill -0 "$heartbeat_adb_pid" >/dev/null 2>&1; then
                break
            fi
            sleep 0.25
        done

        if kill -0 "$heartbeat_adb_pid" >/dev/null 2>&1; then
            kill "$heartbeat_adb_pid" >/dev/null 2>&1
        fi
        wait "$heartbeat_adb_pid" >/dev/null 2>&1
        heartbeat_adb_pid=""
        sleep 2
    done
}

stop_mac_mode() {
    if [ -n "$HEARTBEAT_PID" ]; then
        kill "$HEARTBEAT_PID" >/dev/null 2>&1
        wait "$HEARTBEAT_PID" >/dev/null 2>&1
        HEARTBEAT_PID=""
    fi

    if [ -n "${ADDRESS:-}" ] && adb -s "$ADDRESS" get-state 2>/dev/null | grep -q '^device$'; then
        remote_pid="$(adb -s "$ADDRESS" shell cat "$REMOTE_WATCHDOG_PID" 2>/dev/null | tr -d '\r')"
        case "$remote_pid" in
            ''|*[!0-9]*) ;;
            *) adb -s "$ADDRESS" shell kill "$remote_pid" >/dev/null 2>&1 ;;
        esac
        adb -s "$ADDRESS" shell rm -f "$REMOTE_HEARTBEAT" "$REMOTE_WATCHDOG_PID" >/dev/null 2>&1
    fi
}

start_mac_mode() {
    if [ ! -f "$WATCHDOG_LOCAL" ]; then
        return 1
    fi

    adb -s "$ADDRESS" push "$WATCHDOG_LOCAL" "$REMOTE_WATCHDOG" >/dev/null 2>&1 || return 1
    adb -s "$ADDRESS" shell chmod 700 "$REMOTE_WATCHDOG" >/dev/null 2>&1 || return 1

    old_remote_pid="$(adb -s "$ADDRESS" shell cat "$REMOTE_WATCHDOG_PID" 2>/dev/null | tr -d '\r')"
    case "$old_remote_pid" in
        ''|*[!0-9]*) ;;
        *) adb -s "$ADDRESS" shell kill "$old_remote_pid" >/dev/null 2>&1 ;;
    esac

    adb -s "$ADDRESS" shell rm -f "$REMOTE_WATCHDOG_PID" >/dev/null 2>&1
    adb -s "$ADDRESS" shell touch "$REMOTE_HEARTBEAT" >/dev/null 2>&1 || return 1
    adb -s "$ADDRESS" shell "setsid sh '$REMOTE_WATCHDOG' '$WATCHDOG_GRACE_SECONDS' </dev/null >/dev/null 2>&1 &" >/dev/null 2>&1 || return 1
    sleep 1

    remote_pid="$(adb -s "$ADDRESS" shell cat "$REMOTE_WATCHDOG_PID" 2>/dev/null | tr -d '\r')"
    case "$remote_pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    adb -s "$ADDRESS" shell kill -0 "$remote_pid" >/dev/null 2>&1 || return 1

    heartbeat_loop &
    HEARTBEAT_PID=$!
    return 0
}

wait_for_wifi_reconnect() {
    adb disconnect "$ADDRESS" >/dev/null 2>&1
    for reconnect_attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        connect_wifi "$ADDRESS"
        if adb -s "$ADDRESS" get-state 2>/dev/null | grep -q '^device$'; then
            return 0
        fi
        sleep 1
    done
    return 1
}

cleanup() {
    if [ -n "$CONTROLLER_PID" ]; then
        kill "$CONTROLLER_PID" >/dev/null 2>&1
    fi
    stop_mac_mode
}
trap cleanup EXIT
trap 'exit 130' INT TERM

if ! command -v adb >/dev/null 2>&1 || ! command -v scrcpy >/dev/null 2>&1; then
    echo "Rokidの接続に必要なソフトが見つかりません。"
    pause_and_exit
fi

if [ ! -x "$PYTHON" ] || [ ! -f "$CONTROLLER" ] || [ ! -f "$WATCHDOG_LOCAL" ]; then
    echo "キーボード操作に必要な設定が見つかりません。"
    pause_and_exit
fi

ADDRESS=""
if [ -f "$ADDRESS_FILE" ]; then
    ADDRESS="$(tr -d '[:space:]' < "$ADDRESS_FILE")"
fi

# 前回と同じWi-Fiアドレスへ接続する。
if [ -n "$ADDRESS" ]; then
    connect_wifi "$ADDRESS"
fi

# Rokidの再起動やIP変更で接続できない場合は、USBからWi-Fi接続を自動復旧する。
if [ -z "$ADDRESS" ] || ! adb -s "$ADDRESS" get-state 2>/dev/null | grep -q '^device$'; then
    if [ -n "$ADDRESS" ]; then
        adb disconnect "$ADDRESS" >/dev/null 2>&1
    fi

    USB_SERIAL="$(adb devices | awk 'NR > 1 && $2 == "device" && $1 !~ /:/ { print $1; exit }')"

    if [ -z "$USB_SERIAL" ]; then
        echo "開発用5ピンケーブルを接続してください。接続を最大60秒待ちます..."
        for attempt in $(seq 1 60); do
            USB_SERIAL="$(adb devices | awk 'NR > 1 && $2 == "device" && $1 !~ /:/ { print $1; exit }')"
            if [ -n "$USB_SERIAL" ]; then
                echo "RokidをUSBで認識しました。"
                break
            fi
            sleep 1
        done
    fi

    if [ -z "$USB_SERIAL" ]; then
        USB_STATE="$(adb devices | awk 'NR > 1 && $1 !~ /:/ { print $2; exit }')"
        if [ "$USB_STATE" = "unauthorized" ]; then
            echo "Rokid側に表示されたUSB接続の許可を選んでください。"
        else
            echo "MacがRokidをUSB機器として認識できませんでした。ケーブルを抜き差ししてください。"
        fi
        pause_and_exit
    fi

    echo "RokidのWi-Fiを確認しています..."
    WIFI_STATUS="$(adb -s "$USB_SERIAL" shell cmd wifi status 2>/dev/null)"
    OPENED_WIFI_SETTINGS=0

    # RV101は独自設定にもWi-Fiのオン・オフを保存する。
    # 強制オンでは後からオフへ戻るため、正式な設定画面からオンにする。
    if printf '%s' "$WIFI_STATUS" | grep -q 'Wifi is disabled'; then
        echo "RokidのWi-Fiを正式な設定からオンにしています..."
        adb -s "$USB_SERIAL" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
        adb -s "$USB_SERIAL" shell wm dismiss-keyguard >/dev/null 2>&1
        adb -s "$USB_SERIAL" shell am start -a android.settings.WIFI_SETTINGS >/dev/null 2>&1
        sleep 2
        # RV101は設定画面でもすぐに消灯する。
        # Enterが単なるウェイクアップにならないよう、直前に画面を起こす。
        adb -s "$USB_SERIAL" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
        sleep 0.2
        adb -s "$USB_SERIAL" shell input keyevent KEYCODE_ENTER >/dev/null 2>&1
        OPENED_WIFI_SETTINGS=1
    fi

    ROKID_IP=""
    for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        WIFI_STATUS="$(adb -s "$USB_SERIAL" shell cmd wifi status 2>/dev/null)"
        ROKID_IP="$(adb -s "$USB_SERIAL" shell ip -4 addr show wlan0 2>/dev/null | awk '/inet / { split($2, a, "/"); print a[1]; exit }')"
        if [ -n "$ROKID_IP" ] && printf '%s' "$WIFI_STATUS" | grep -q 'Wifi is connected to'; then
            break
        fi
        ROKID_IP=""
        sleep 1
    done

    if [ -z "$ROKID_IP" ]; then
        echo "Rokidを自宅Wi-Fiへ接続できませんでした。"
        pause_and_exit
    fi

    if [ "$OPENED_WIFI_SETTINGS" -eq 1 ]; then
        adb -s "$USB_SERIAL" shell input keyevent KEYCODE_BACK >/dev/null 2>&1
    fi

    ADDRESS="$ROKID_IP:5555"
    echo "Wi-Fi接続を再設定しています..."
    adb disconnect "$ADDRESS" >/dev/null 2>&1
    adb -s "$USB_SERIAL" tcpip 5555 >/dev/null
    sleep 2

    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        connect_wifi "$ADDRESS"
        if adb -s "$ADDRESS" get-state 2>/dev/null | grep -q '^device$'; then
            break
        fi
        sleep 1
    done

    if adb -s "$ADDRESS" get-state 2>/dev/null | grep -q '^device$'; then
        printf '%s\n' "$ADDRESS" > "$ADDRESS_FILE"
    fi
fi

if ! adb -s "$ADDRESS" get-state 2>/dev/null | grep -q '^device$'; then
    echo "RokidへWi-Fi接続できませんでした。MacとRokidを同じWi-Fiにつないでください。"
    pause_and_exit
fi

if ! "$PYTHON" -c 'import ApplicationServices as A; raise SystemExit(0 if A.AXIsProcessTrusted() else 1)'; then
    "$PYTHON" -c 'import ApplicationServices as A; A.AXIsProcessTrustedWithOptions({A.kAXTrustedCheckOptionPrompt: True})'
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    echo "開いた設定画面で『ターミナル』を許可してから、もう一度実行してください。"
    pause_and_exit
fi

if ! start_mac_mode; then
    echo "Mac操作モードのWi-Fi監視を開始できませんでした。"
    pause_and_exit
fi

echo "RokidへWi-Fi接続しました。USBケーブルを外して使えます。"
echo "Mac操作モード：Wi-Fiが切れても自動で復旧します。"
echo "操作：マウス / ←→ 上段アプリ / Enter 決定 / Esc 戻る / H 中央のHome"
echo "      Shift+← メモ / Shift+→ アプリ一覧"
echo "      スペース 画面中央 / 素早く2回でダブルタップ"

"$PYTHON" "$CONTROLLER" --serial "$ADDRESS" &
CONTROLLER_PID=$!
sleep 1

if ! kill -0 "$CONTROLLER_PID" >/dev/null 2>&1; then
    echo "キーボード操作を開始できませんでした。"
    pause_and_exit
fi

# マウス操作は有効のまま、キーボードはRV101用コントローラーで処理する。
while true; do
    scrcpy --serial "$ADDRESS" --no-audio --keyboard=disabled \
        --window-title="Rokid Glasses RV101（Mac操作モード）"
    scrcpy_result=$?

    # ウィンドウを閉じた場合は通常終了。通信切断時だけ再接続する。
    if [ "$scrcpy_result" -eq 0 ]; then
        break
    fi

    echo "RokidのWi-Fiが一時的に切れました。自動復旧中です..."
    if wait_for_wifi_reconnect; then
        echo "Wi-Fi接続を復旧しました。Rokid画面を再表示します。"
    else
        echo "Wi-Fi接続を自動復旧できませんでした。"
        pause_and_exit
    fi
done
