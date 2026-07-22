#!/bin/bash

set -e
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV="$SCRIPT_DIR/.venv-rokid-keyboard"

pause_and_exit() {
    read -r -p "Enterキーで処理を終了します..."
    exit 1
}

if ! command -v brew >/dev/null 2>&1; then
    echo "先にHomebrewをインストールしてください: https://brew.sh/ja/"
    pause_and_exit
fi

echo "Rokid操作に必要なソフトを準備しています..."
if brew install --help | grep -q -- '--no-ask'; then
    brew install --yes android-platform-tools scrcpy
else
    brew install android-platform-tools scrcpy
fi

# macOS付属のPythonを優先する。Python 3.14ではmacOSのキー入力監視が
# 起動していても反応しないことがあるため、3.9〜3.13を使用する。
PYTHON_BIN="/usr/bin/python3"
if ! "$PYTHON_BIN" -c 'import sys, venv; raise SystemExit(not ((3, 9) <= sys.version_info[:2] < (3, 14)))' >/dev/null 2>&1; then
    echo "安定版のPythonを準備しています..."
    if brew install --help | grep -q -- '--no-ask'; then
        brew install --yes python@3.13
    else
        brew install python@3.13
    fi
    PYTHON_BIN="$(brew --prefix python@3.13)/bin/python3.13"
fi

"$PYTHON_BIN" -m venv --clear "$VENV"
"$VENV/bin/python" -m pip install --upgrade pip
"$VENV/bin/python" -m pip install -r "$SCRIPT_DIR/requirements.txt"

echo
echo "セットアップが完了しました。"
echo "『Rokid操作【Wi-Fi・マウス・キーボード】.command』をダブルクリックしてください。"
read -r -p "Enterキーで処理を終了します..."
