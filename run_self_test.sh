#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
TEST_BINARY="$BUILD/VisionCompositorSelfTest"
OUTPUT="$BUILD/vision-compositor-self-test.png"

mkdir -p "$BUILD"

xcrun swiftc \
    -O \
    -swift-version 5 \
    -parse-as-library \
    -target arm64-apple-macos12.3 \
    -framework AppKit \
    -framework CoreImage \
    -framework CoreMedia \
    -framework CoreVideo \
    -framework ScreenCaptureKit \
    -o "$TEST_BINARY" \
    "$ROOT/Sources/VisionCompositor.swift" \
    "$ROOT/Tests/VisionCompositorSelfTest.swift"

"$TEST_BINARY" "$OUTPUT"
