#!/bin/bash

set -e
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV="$SCRIPT_DIR/.venv-rokid-keyboard"

pause_and_exit() {
    read -r -p "Enterキーで閉じます..."
    exit 1
}

if ! command -v brew >/dev/null 2>&1; then
    echo "先にHomebrewをインストールしてください: https://brew.sh/ja/"
    pause_and_exit
fi

echo "Rokid操作に必要なソフトを準備しています..."
brew install android-platform-tools scrcpy python

python3 -m venv "$VENV"
"$VENV/bin/python" -m pip install --upgrade pip
"$VENV/bin/python" -m pip install -r "$SCRIPT_DIR/requirements.txt"

echo
echo "セットアップが完了しました。"
echo "『Rokid操作【Wi-Fi・マウス・キーボード】.command』をダブルクリックしてください。"
read -r -p "Enterキーで閉じます..."

