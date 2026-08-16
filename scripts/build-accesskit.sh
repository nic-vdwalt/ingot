#!/bin/bash
# build-accesskit.sh - Fetch the prebuilt AccessKit C API libraries from the
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
ARCHIVE_SHA256="b652e380fb78efe6721ad892f15b2224f38f661c3fb20436ef4c5b3ce0fe8177"
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
if command -v sha256sum >/dev/null 2>&1; then
    actual_sha256="$(sha256sum "$TMP/accesskit-c.zip" | cut -d' ' -f1)"
elif command -v shasum >/dev/null 2>&1; then
    actual_sha256="$(shasum -a 256 "$TMP/accesskit-c.zip" | cut -d' ' -f1)"
else
    echo "Neither sha256sum nor shasum is available" >&2
    exit 1
fi
if [ "$VERSION" = "0.22.3" ] && [ "$actual_sha256" != "$ARCHIVE_SHA256" ]; then
    echo "AccessKit source archive checksum mismatch" >&2
    exit 1
fi
unzip -q "$TMP/accesskit-c.zip" -d "$TMP"
SRC="$TMP/accesskit-c-$VERSION"

install_lib() { # <release subdir> <dest platform_arch> <lib file>
    mkdir -p "$SCRIPT_DIR/accesskit/lib/$2"
    cp "$SRC/lib/$1/$3" "$SCRIPT_DIR/accesskit/lib/$2/"
    echo "Installed accesskit/lib/$2/$3"
}

# macOS: wgpu_native (vendor:wgpu) is also a Rust staticlib, so linking both
# collides on Rust runtime symbols (rust_eh_personality). Prelink the archive
# into one object exporting only accesskit_* symbols; everything else becomes
# a private extern and can no longer collide.
#
# `ld -r` keeps the upstream debug map (N_OSO stabs) pointing at the temporary
# unpack directory, so every consumer -debug link warns "unable to open object
# file" for each Rust codegen unit once that directory is gone. `strip -S` drops
# the debug symbols and the stale references with them.
install_lib_macos() { # <ld arch> <dest platform_arch>
    local tmp_o exports
    tmp_o="$(mktemp -d)/ak_$1.o"
    exports="$(mktemp)"
    printf '_accesskit_*\n_ACCESSKIT_*\n' > "$exports"
    mkdir -p "$SCRIPT_DIR/accesskit/lib/$2"
    ld -r -arch "$1" -platform_version macos 11.0 11.0 \
        -force_load "$SRC/lib/macos/$1/static/libaccesskit.a" \
        -exported_symbols_list "$exports" -o "$tmp_o"
    strip -S "$tmp_o"
    rm -f "$SCRIPT_DIR/accesskit/lib/$2/libaccesskit.a"
    ar rcs "$SCRIPT_DIR/accesskit/lib/$2/libaccesskit.a" "$tmp_o"
    echo "Installed accesskit/lib/$2/libaccesskit.a (prelinked, accesskit_* only)"
}

if [ "$ALL" = 1 ]; then
    install_lib_macos arm64 darwin_arm64
    install_lib_macos x86_64 darwin_amd64
    install_lib windows/x86_64/msvc/static windows_amd64 accesskit.lib
    install_lib linux/x86_64/static linux_amd64 libaccesskit.a
else
    case "$(uname -s)-$(uname -m)" in
        Darwin-arm64)  install_lib_macos arm64 darwin_arm64 ;;
        Darwin-x86_64) install_lib_macos x86_64 darwin_amd64 ;;
        Linux-x86_64)  install_lib linux/x86_64/static linux_amd64 libaccesskit.a ;;
        Linux-aarch64|Linux-arm64)
            echo "AccessKit 0.22.3 has no verified Linux arm64 artifact" >&2
            exit 1
            ;;
        *) echo "Unsupported platform; use --all or copy manually"; exit 1 ;;
    esac
fi

# Keep the reference header in sync with the vendored libraries.
mkdir -p "$SCRIPT_DIR/accesskit/include"
cp "$SRC/include/accesskit.h" "$SCRIPT_DIR/accesskit/include/"
echo "Installed accesskit/include/accesskit.h"
