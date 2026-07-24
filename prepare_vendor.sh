#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
VENDOR="$ROOT/vendor"
VERSION="4.1"

ARM_ARCHIVE="$VENDOR/scrcpy-macos-aarch64-v$VERSION.tar.gz"
INTEL_ARCHIVE="$VENDOR/scrcpy-macos-x86_64-v$VERSION.tar.gz"
ARM_DIR="$VENDOR/extracted-aarch64"
INTEL_DIR="$VENDOR/extracted-x86_64"

ARM_URL="https://github.com/Genymobile/scrcpy/releases/download/v$VERSION/scrcpy-macos-aarch64-v$VERSION.tar.gz"
INTEL_URL="https://github.com/Genymobile/scrcpy/releases/download/v$VERSION/scrcpy-macos-x86_64-v$VERSION.tar.gz"

ARM_SHA256="20fd47c9014dd5e0fa77091f3cb7adbda8445a360c4584aeaa0150b5b3988ff3"
INTEL_SHA256="ee2a7223bc8dbdc4f482db1134bcf441178dafb833492b71ca4c22090c58ce72"

mkdir -p "$VENDOR"

download_and_verify() {
    local url="$1"
    local archive="$2"
    local expected="$3"

    if [[ ! -f "$archive" ]]; then
        curl --fail --location --retry 3 --output "$archive.part" "$url"
        mv "$archive.part" "$archive"
    fi

    local actual
    actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
        echo "Checksum mismatch: $archive" >&2
        exit 1
    fi
}

extract_archive() {
    local archive="$1"
    local destination="$2"

    if [[ -x "$destination/scrcpy" && -x "$destination/adb" ]]; then
        return
    fi

    rm -rf "$destination"
    mkdir -p "$destination"
    tar -xzf "$archive" -C "$destination" --strip-components=1
}

download_and_verify "$ARM_URL" "$ARM_ARCHIVE" "$ARM_SHA256"
download_and_verify "$INTEL_URL" "$INTEL_ARCHIVE" "$INTEL_SHA256"
extract_archive "$ARM_ARCHIVE" "$ARM_DIR"
extract_archive "$INTEL_ARCHIVE" "$INTEL_DIR"

echo "scrcpy $VERSION dependencies are ready."
