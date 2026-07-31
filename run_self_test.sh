#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
TEST_BINARY="$BUILD/VisionCompositorSelfTest"
RUNNER_TEST_BINARY="$BUILD/ProcessRunnerSelfTest"
NAVIGATION_TEST_BINARY="$BUILD/KeyboardNavigationSelfTest"
ENCRYPTION_TEST_BINARY="$BUILD/ConnectionEncryptionSelfTest"
SCREEN_TIMEOUT_TEST_BINARY="$BUILD/ScreenTimeoutPolicySelfTest"
ADB_SERVER_POLICY_TEST_BINARY="$BUILD/ADBServerPolicySelfTest"
OUTPUT="$BUILD/vision-compositor-self-test.png"
INFO_PLIST="$ROOT/Resources/RokidControl-Info.plist"

mkdir -p "$BUILD"

HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
    arm64|x86_64) ;;
    *)
        echo "Unsupported Mac architecture: $HOST_ARCH" >&2
        exit 1
        ;;
esac

xcrun swiftc \
    -O \
    -swift-version 5 \
    -parse-as-library \
    -target "$HOST_ARCH-apple-macos12.3" \
    -framework AppKit \
    -framework CoreImage \
    -framework CoreMedia \
    -framework CoreVideo \
    -framework ScreenCaptureKit \
    -o "$TEST_BINARY" \
    "$ROOT/Sources/KeyboardNavigation.swift" \
    "$ROOT/Sources/VisionCompositor.swift" \
    "$ROOT/Tests/VisionCompositorSelfTest.swift"

"$TEST_BINARY" "$OUTPUT"

xcrun swiftc \
    -O \
    -swift-version 5 \
    -parse-as-library \
    -target "$HOST_ARCH-apple-macos12.3" \
    -o "$RUNNER_TEST_BINARY" \
    "$ROOT/Sources/ProcessRunner.swift" \
    "$ROOT/Tests/ProcessRunnerSelfTest.swift"

"$RUNNER_TEST_BINARY"

xcrun swiftc \
    -O \
    -swift-version 5 \
    -parse-as-library \
    -target "$HOST_ARCH-apple-macos12.3" \
    -o "$NAVIGATION_TEST_BINARY" \
    "$ROOT/Sources/KeyboardNavigation.swift" \
    "$ROOT/Sources/KeyboardCommandRouter.swift" \
    "$ROOT/Tests/KeyboardNavigationSelfTest.swift"

"$NAVIGATION_TEST_BINARY"

xcrun swiftc \
    -O \
    -swift-version 5 \
    -parse-as-library \
    -target "$HOST_ARCH-apple-macos12.3" \
    -o "$SCREEN_TIMEOUT_TEST_BINARY" \
    "$ROOT/Sources/ScreenTimeoutPolicy.swift" \
    "$ROOT/Tests/ScreenTimeoutPolicySelfTest.swift"

"$SCREEN_TIMEOUT_TEST_BINARY"

xcrun swiftc \
    -O \
    -swift-version 5 \
    -parse-as-library \
    -target "$HOST_ARCH-apple-macos12.3" \
    -o "$ENCRYPTION_TEST_BINARY" \
    "$ROOT/Sources/ConnectionEncryption.swift" \
    "$ROOT/Tests/ConnectionEncryptionSelfTest.swift"

"$ENCRYPTION_TEST_BINARY"

xcrun swiftc \
    -O \
    -swift-version 5 \
    -parse-as-library \
    -target "$HOST_ARCH-apple-macos12.3" \
    -o "$ADB_SERVER_POLICY_TEST_BINARY" \
    "$ROOT/Sources/ADBServerPolicy.swift" \
    "$ROOT/Tests/ADBServerPolicySelfTest.swift"

"$ADB_SERVER_POLICY_TEST_BINARY"

LOCAL_NETWORK_DESCRIPTION="$(
    /usr/libexec/PlistBuddy \
        -c "Print :NSLocalNetworkUsageDescription" \
        "$INFO_PLIST"
)"
BONJOUR_SERVICE="$(
    /usr/libexec/PlistBuddy \
        -c "Print :NSBonjourServices:0" \
        "$INFO_PLIST"
)"
test -n "$LOCAL_NETWORK_DESCRIPTION"
test "$BONJOUR_SERVICE" = "_adb-tls-connect._tcp"
echo "Bundle metadata self-test passed"
