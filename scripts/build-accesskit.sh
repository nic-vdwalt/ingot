#!/bin/bash
# build-accesskit.sh — Fetch the prebuilt AccessKit C API libraries from the
# official accesskit-c release and place them in ingot/accesskit/lib/
# <platform_arch>/ where the Odin bindings' relative foreign import finds
# them (no linker flags needed by consumers). The release zip ships static
# libraries built by AccessKit's CI for every supported platform, so unlike
# libvterm there is nothing to compile locally (building from source would
# require a Rust toolchain).
#
# Usage:
#   ./scripts/build-accesskit.sh [--version 0.22.3] [--all]
#
# Without --all only the current platform's library is installed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="0.22.3"
ALL=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --all) ALL=1; shift ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

URL="https://github.com/AccessKit/accesskit-c/releases/download/$VERSION/accesskit-c-$VERSION.zip"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Fetching accesskit-c $VERSION..."
curl -fsSL "$URL" -o "$TMP/accesskit-c.zip"
unzip -q "$TMP/accesskit-c.zip" -d "$TMP"
SRC="$TMP/accesskit-c-$VERSION"

install_lib() { # <release subdir> <dest platform_arch> <lib file>
    mkdir -p "$SCRIPT_DIR/accesskit/lib/$2"
    cp "$SRC/lib/$1/$3" "$SCRIPT_DIR/accesskit/lib/$2/"
    echo "Installed accesskit/lib/$2/$3"
}

if [ "$ALL" = 1 ]; then
    install_lib macos/arm64/static darwin_arm64 libaccesskit.a
    install_lib macos/x86_64/static darwin_amd64 libaccesskit.a
    install_lib windows/x86_64/msvc/static windows_amd64 accesskit.lib
    install_lib linux/x86_64/static linux_amd64 libaccesskit.a
else
    case "$(uname -s)-$(uname -m)" in
        Darwin-arm64)  install_lib macos/arm64/static darwin_arm64 libaccesskit.a ;;
        Darwin-x86_64) install_lib macos/x86_64/static darwin_amd64 libaccesskit.a ;;
        Linux-x86_64)  install_lib linux/x86_64/static linux_amd64 libaccesskit.a ;;
        *) echo "Unsupported platform; use --all or copy manually"; exit 1 ;;
    esac
fi

# Keep the reference header in sync with the vendored libraries.
mkdir -p "$SCRIPT_DIR/accesskit/include"
cp "$SRC/include/accesskit.h" "$SCRIPT_DIR/accesskit/include/"
echo "Installed accesskit/include/accesskit.h"
