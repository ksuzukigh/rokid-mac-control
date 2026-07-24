#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SOURCES="$ROOT/Sources"
RESOURCES="$ROOT/Resources"
VENDOR="$ROOT/vendor"
BUILD="$ROOT/build"
APP="$BUILD/Rokid Control.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
APP_RESOURCES="$CONTENTS/Resources"
BIN="$APP_RESOURCES/bin"
SCRCPY_APP="$APP_RESOURCES/Scrcpy.app"
SCRCPY_CONTENTS="$SCRCPY_APP/Contents"
SCRCPY_MACOS="$SCRCPY_CONTENTS/MacOS"
SCRCPY_RESOURCES="$SCRCPY_CONTENTS/Resources"
LICENSES="$APP_RESOURCES/Licenses"
STAGING="$BUILD/dmg"
DMG="$BUILD/Rokid Control.dmg"

"$ROOT/prepare_vendor.sh"

rm -rf "$BUILD"
mkdir -p \
    "$MACOS" \
    "$BIN" \
    "$SCRCPY_MACOS" \
    "$SCRCPY_RESOURCES" \
    "$LICENSES" \
    "$STAGING"

ARM_BINARY="$BUILD/Rokid Control-arm64"
INTEL_BINARY="$BUILD/Rokid Control-x86_64"

xcrun swiftc \
    -O \
    -parse-as-library \
    -target arm64-apple-macos11.0 \
    -framework AppKit \
    -framework ApplicationServices \
    -o "$ARM_BINARY" \
    "$SOURCES"/*.swift

xcrun swiftc \
    -O \
    -parse-as-library \
    -target x86_64-apple-macos11.0 \
    -framework AppKit \
    -framework ApplicationServices \
    -o "$INTEL_BINARY" \
    "$SOURCES"/*.swift

lipo -create "$ARM_BINARY" "$INTEL_BINARY" -output "$MACOS/Rokid Control"
lipo -create \
    "$VENDOR/extracted-aarch64/scrcpy" \
    "$VENDOR/extracted-x86_64/scrcpy" \
    -output "$SCRCPY_MACOS/scrcpy"

cp "$VENDOR/extracted-aarch64/adb" "$BIN/adb"
cp "$VENDOR/extracted-aarch64/scrcpy.png" "$SCRCPY_RESOURCES/scrcpy.png"
cp "$VENDOR/extracted-aarch64/disconnected.png" "$SCRCPY_RESOURCES/disconnected.png"
cp "$RESOURCES/Scrcpy-Info.plist" "$SCRCPY_CONTENTS/Info.plist"
cp "$VENDOR/extracted-aarch64/scrcpy-server" "$APP_RESOURCES/scrcpy-server"
cp "$RESOURCES/RokidControl-Info.plist" "$CONTENTS/Info.plist"
cp "$RESOURCES/rokid_wifi_watchdog.sh" "$APP_RESOURCES/rokid_wifi_watchdog.sh"
cp "$RESOURCES/RokidGlasses.icns" "$APP_RESOURCES/RokidGlasses.icns"
cp "$RESOURCES/THIRD-PARTY-NOTICES.md" "$LICENSES/THIRD-PARTY-NOTICES.md"
cp "$VENDOR/extracted-aarch64/LICENSE" "$LICENSES/scrcpy-LICENSE"
cp \
    "$VENDOR/Android-Platform-Tools-NOTICE.txt" \
    "$LICENSES/Android-Platform-Tools-NOTICE.txt"

chmod 755 \
    "$MACOS/Rokid Control" \
    "$BIN/adb" \
    "$SCRCPY_MACOS/scrcpy" \
    "$APP_RESOURCES/rokid_wifi_watchdog.sh"

codesign --force --sign - "$BIN/adb"
codesign --force --sign - "$SCRCPY_APP"
codesign \
    --force \
    --deep \
    --sign - \
    --requirements '=designated => identifier "io.github.ksuzukigh.rokid-mac-control"' \
    "$APP"

cp -R "$APP" "$STAGING/Rokid Control.app"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
    -volname "Rokid Control" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG" >/dev/null

printf 'Built: %s\n' "$APP"
printf 'Built: %s\n' "$DMG"
