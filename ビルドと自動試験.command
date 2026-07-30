#!/bin/bash
# Finderでダブルクリックすると、自動試験→警告チェック→アプリとDMGの作成を
# 順に実行する。ターミナルにコマンドを打ち込む必要はない。

cd "$(dirname "$0")" || exit 1
ROOT="$(pwd)"

printf '\n===== Rokid Control ビルドと自動試験 =====\n\n'

finish() {
    printf '\nこのウインドウは閉じて構いません。\n'
    exit "$1"
}

printf '[1/3] 自動試験を実行しています…\n\n'
if ! ./run_self_test.sh; then
    printf '\n【結果】自動試験に失敗しました。上の赤い行が原因です。\n'
    finish 1
fi
printf '\n[1/3] 自動試験に合格しました。\n'

printf '\n[2/3] 全ソースを警告なしでビルドできるか確認しています…\n'
WARNINGS="$(mktemp)"
if ! xcrun swiftc \
    -swift-version 5 \
    -parse-as-library \
    -typecheck \
    -target "$(uname -m)-apple-macos12.3" \
    -framework AppKit \
    -framework ApplicationServices \
    -framework CoreImage \
    -framework CoreMedia \
    -framework CoreVideo \
    -framework ScreenCaptureKit \
    "$ROOT/Sources"/*.swift 2>"$WARNINGS"; then
    printf '\n【結果】ビルドエラーがあります。\n\n'
    cat "$WARNINGS"
    rm -f "$WARNINGS"
    finish 1
fi
if grep -q "warning:" "$WARNINGS"; then
    printf '\n【結果】ビルドは通りましたが警告があります。\n\n'
    grep "warning:" "$WARNINGS"
    rm -f "$WARNINGS"
    finish 1
fi
rm -f "$WARNINGS"
printf '[2/3] 警告・エラーなしで確認できました。\n'

printf '\n[3/3] アプリとDMGを作成しています…（数分かかります）\n\n'
if ! ./build_dmg.sh; then
    printf '\n【結果】アプリの作成に失敗しました。\n'
    finish 1
fi

printf '\n【結果】すべて成功しました。\n'
printf '作成物: %s\n' "$ROOT/build/Rokid Control.app"
printf '作成物: %s\n' "$ROOT/build/Rokid Control.dmg"
finish 0
