#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Rokid Control.app"
INSTALL_PATH="/Applications/$APP_NAME"
LEGACY_INSTALL_PATH="/Applications/Rokid Glasses.app"
BUILD_ROOT="$(mktemp -d /tmp/rokid-control-app.XXXXXX)"
BUILD_APP="$BUILD_ROOT/$APP_NAME"

cleanup() {
    rm -rf "$BUILD_ROOT"
}
trap cleanup EXIT

if ! command -v xcrun >/dev/null 2>&1; then
    echo "Macアプリを作るためのソフトが見つかりません。"
    echo "ターミナルで xcode-select --install を実行してから、もう一度お試しください。"
    exit 1
fi

mkdir -p "$BUILD_APP/Contents/MacOS" "$BUILD_APP/Contents/Resources"

xcrun swiftc \
    -O \
    -parse-as-library \
    -framework AppKit \
    -o "$BUILD_APP/Contents/MacOS/Rokid Control" \
    "$SCRIPT_DIR/RokidControlApp.swift"

cp "$SCRIPT_DIR/RokidControl-Info.plist" "$BUILD_APP/Contents/Info.plist"
cp "$SCRIPT_DIR/RokidGlasses.icns" "$BUILD_APP/Contents/Resources/RokidGlasses.icns"
printf '%s\n' "$SCRIPT_DIR" > "$BUILD_APP/Contents/Resources/tool_path.txt"

codesign \
    --force \
    --deep \
    --sign - \
    --requirements '=designated => identifier "io.github.ksuzukigh.rokid-mac-control"' \
    "$BUILD_APP" >/dev/null

if [ -e "$INSTALL_PATH" ]; then
    rm -rf "$INSTALL_PATH"
fi
mv "$BUILD_APP" "$INSTALL_PATH"
touch "$INSTALL_PATH"

DOCK_EXPORT="$BUILD_ROOT/dock.plist"
DOCK_UPDATED="$BUILD_ROOT/dock-updated.plist"
if defaults export com.apple.dock "$DOCK_EXPORT" >/dev/null 2>&1; then
    /usr/bin/python3 - "$DOCK_EXPORT" "$DOCK_UPDATED" <<'PY'
import plistlib
import sys

source, destination = sys.argv[1:3]
with open(source, "rb") as handle:
    dock = plistlib.load(handle)

items = dock.get("persistent-apps", [])
dock["persistent-apps"] = [
    item
    for item in items
    if item.get("tile-data", {}).get("bundle-identifier")
    != "io.github.ksuzukigh.rokid-mac-control"
]

with open(destination, "wb") as handle:
    plistlib.dump(dock, handle)
PY
    defaults import com.apple.dock "$DOCK_UPDATED" >/dev/null
fi

if [ -e "$LEGACY_INSTALL_PATH" ]; then
    rm -rf "$LEGACY_INSTALL_PATH"
fi

if ! defaults read com.apple.dock persistent-apps 2>/dev/null |
    grep -q "Rokid Control"; then
    defaults write com.apple.dock persistent-apps -array-add \
        '{"tile-data"={"bundle-identifier"="io.github.ksuzukigh.rokid-mac-control";"file-data"={"_CFURLString"="file:///Applications/Rokid%20Control.app/";"_CFURLStringType"=15;};"file-label"="Rokid Control";};"tile-type"="file-tile";}'
fi
killall Dock >/dev/null 2>&1 || true

echo "『Rokid Control』をアプリケーションフォルダへ追加しました。"
echo "Dockにも『Rokid Control』を追加しました。"
