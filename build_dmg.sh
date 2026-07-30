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
    -swift-version 5 \
    -parse-as-library \
    -target arm64-apple-macos12.3 \
    -framework AppKit \
    -framework ApplicationServices \
    -framework CoreImage \
    -framework CoreMedia \
    -framework CoreVideo \
    -framework ScreenCaptureKit \
    -o "$ARM_BINARY" \
    "$SOURCES"/*.swift

xcrun swiftc \
    -O \
    -swift-version 5 \
    -parse-as-library \
    -target x86_64-apple-macos12.3 \
    -framework AppKit \
    -framework ApplicationServices \
    -framework CoreImage \
    -framework CoreMedia \
    -framework CoreVideo \
    -framework ScreenCaptureKit \
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
cp "$ROOT/LICENSE" "$LICENSES/Rokid-Control-LICENSE"
cp "$RESOURCES/THIRD-PARTY-NOTICES.md" "$LICENSES/THIRD-PARTY-NOTICES.md"
cp "$VENDOR/extracted-aarch64/LICENSE" "$LICENSES/scrcpy-LICENSE"
cp \
    "$VENDOR/Android-Platform-Tools-NOTICE.txt" \
    "$LICENSES/Android-Platform-Tools-NOTICE.txt"

LOCAL_NETWORK_DESCRIPTION="$(
    /usr/libexec/PlistBuddy \
        -c "Print :NSLocalNetworkUsageDescription" \
        "$CONTENTS/Info.plist"
)"
BONJOUR_SERVICE="$(
    /usr/libexec/PlistBuddy \
        -c "Print :NSBonjourServices:0" \
        "$CONTENTS/Info.plist"
)"
test -n "$LOCAL_NETWORK_DESCRIPTION"
test "$BONJOUR_SERVICE" = "_adb-tls-connect._tcp"

chmod 755 \
    "$MACOS/Rokid Control" \
    "$BIN/adb" \
    "$SCRCPY_MACOS/scrcpy" \
    "$APP_RESOURCES/rokid_wifi_watchdog.sh"

ADB_ARCHS="$(lipo -archs "$BIN/adb")"
case " $ADB_ARCHS " in
    *" arm64 "*) ;;
    *) echo "同梱adbにarm64版がありません: $ADB_ARCHS" >&2; exit 1 ;;
esac
case " $ADB_ARCHS " in
    *" x86_64 "*) ;;
    *) echo "同梱adbにx86_64版がありません: $ADB_ARCHS" >&2; exit 1 ;;
esac

codesign --force --sign - "$BIN/adb"
codesign --force --sign - "$SCRCPY_APP"
codesign \
    --force \
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
