#!/system/bin/sh

# R08 2.0.1の受け付け済み実キーだけを、RV101の純正設定画面へ橋渡しする。
# 昔のログ、ADB試験入力、ほかのアプリ、画面休止中には方向キーを送らない。
PIDFILE=/data/local/tmp/rokid_control_r08_direction.pid
LOGFILE=/data/local/tmp/rokid_control_r08_direction.log
SELF=/data/local/tmp/rokid_control_r08_direction.sh
FIFO=/data/local/tmp/rokid_control_r08_direction.fifo
VERSION=1
R08_UID="$2"

is_ours() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ -r "/proc/$1/cmdline" ] || return 1
    tr '\000' '\n' < "/proc/$1/cmdline" | grep -Fx "$SELF" >/dev/null
}

setting_foreground() {
    dumpsys activity activities | awk '
      /topResumedActivity=|^[[:space:]]*mResumedActivity:|^[[:space:]]*ResumedActivity:/ {
        if ($0 ~ /com[.]rokid[.]os[.]sprite[.]launcher\/(com[.]rokid[.]os[.]sprite[.]launcher)?[.]page[.](volume[.]SettingVolumeActivity|brightness[.]SettingBrightnessActivity)[[:space:]}]/) found=1
      }
      END {exit !found}'
}

log_line() { echo "$(date +%s) $*" >> "$LOGFILE"; }

case "$1" in
 status)
    pid="$(cat "$PIDFILE" 2>/dev/null)"
    if is_ours "$pid"; then echo "running pid=$pid version=$VERSION"; else echo 'not running'; exit 1; fi
    exit 0 ;;
 stop)
    pid="$(cat "$PIDFILE" 2>/dev/null)"
    if is_ours "$pid"; then kill "$pid"; fi
    rm -f "$PIDFILE"
    exit 0 ;;
 start)
    case "$R08_UID" in ''|*[!0-9]*) exit 2 ;; esac
    pid="$(cat "$PIDFILE" 2>/dev/null)"
    if is_ours "$pid"; then echo "already running pid=$pid"; exit 0; fi
    nohup sh "$SELF" run "$R08_UID" </dev/null >/dev/null 2>&1 &
    sleep 0.3
    sh "$SELF" status
    exit $? ;;
 run) case "$R08_UID" in ''|*[!0-9]*) exit 2 ;; esac ;;
 *) exit 2 ;;
esac

echo "$$" > "$PIDFILE"
cleanup() {
    [ -z "$LOG_PID" ] || kill "$LOG_PID" 2>/dev/null
    if [ "$(cat "$PIDFILE" 2>/dev/null)" = "$$" ]; then
        rm -f "$PIDFILE"
        [ ! -p "$FIFO" ] || rm -f "$FIFO"
    fi
}
trap cleanup EXIT
trap 'exit 0' HUP INT TERM
# 起動直前の履歴も再生しない。接続準備中の最初の2秒だけは受け付けない。
start_after=$(($(date +%s) + 2))
log_line "start pid=$$ uid=$R08_UID version=$VERSION"
[ ! -e "$FIFO" ] || [ -p "$FIFO" ] || exit 1
[ -p "$FIFO" ] || mkfifo -m 600 "$FIFO" || exit 1
logcat -v epoch -v uid -s R08Bridge:D '*:S' > "$FIFO" &
LOG_PID=$!
while IFS= read -r line; do
    set -- $line
    [ "$#" -ge 8 ] || continue
    stamp="${1%%.*}"
    case "$stamp" in ''|*[!0-9]*) continue ;; esac
    [ "$2" = "$R08_UID" ] || continue
    now=$(date +%s)
    [ "$stamp" -gt "$start_after" ] && [ "$stamp" -ge $((now - 2)) ] && [ "$stamp" -le "$now" ] || continue
    case "$line" in
      *' R08Bridge: R08 forward from key:87 launcherSteps='*) key=22 ;;
      *' R08Bridge: R08 backward from key:88 launcherSteps='*) key=21 ;;
      *) continue ;;
    esac
    # 起床用の最初の操作は、R08側で消費されて上記ログへ届かない。
    setting_foreground || continue
    input keyevent "$key" >/dev/null 2>&1 && log_line "setting key=$key source_stamp=$1"
done < "$FIFO"
