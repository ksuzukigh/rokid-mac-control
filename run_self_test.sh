#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
TEST_BINARY="$BUILD/VisionCompositorSelfTest"
RUNNER_TEST_BINARY="$BUILD/ProcessRunnerSelfTest"
NAVIGATION_TEST_BINARY="$BUILD/KeyboardNavigationSelfTest"
OUTPUT="$BUILD/vision-compositor-self-test.png"

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
