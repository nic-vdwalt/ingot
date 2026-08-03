#!/bin/bash
# build-libvterm.sh - Build the libvterm static library from the vendored
# source in ingot/vendor/libvterm/. The resulting libvterm.a is placed in
# ingot/libvterm/lib/<platform_arch>/ where the Odin bindings' relative
# foreign import finds it (no linker flags needed by consumers).
#
# Usage:
#   ./scripts/build-libvterm.sh [--target darwin_arm64|darwin_amd64|linux_amd64|linux_arm64]
#
# Without --target the script auto-detects the current platform and arch. A
# target must match the native host because this script does not provide a
# cross compiler or sysroot.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$SCRIPT_DIR/vendor/libvterm/src"
INC_DIR="$SCRIPT_DIR/vendor/libvterm/include"

# --- Argument parsing ---
TARGET=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --target) TARGET="$2"; shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

# --- Detect platform / arch ---
if [ -z "$TARGET" ]; then
    case "$(uname -s)" in
        Darwin*) PLATFORM="darwin" ;;
        Linux*)  PLATFORM="linux" ;;
        *) echo "Unsupported platform"; exit 1 ;;
    esac
    case "$(uname -m)" in
        arm64|aarch64) ARCH="arm64" ;;
        x86_64|amd64)  ARCH="amd64" ;;
        *) echo "Unsupported arch: $(uname -m)"; exit 1 ;;
    esac
    PLATFORM_ARCH="${PLATFORM}_${ARCH}"
else
    PLATFORM_ARCH="$TARGET"
fi

case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) HOST_PLATFORM_ARCH="darwin_arm64" ;;
    Darwin-x86_64) HOST_PLATFORM_ARCH="darwin_amd64" ;;
    Linux-aarch64|Linux-arm64) HOST_PLATFORM_ARCH="linux_arm64" ;;
    Linux-x86_64|Linux-amd64) HOST_PLATFORM_ARCH="linux_amd64" ;;
    *) echo "Unsupported host: $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac
if [ "$PLATFORM_ARCH" != "$HOST_PLATFORM_ARCH" ]; then
    echo "Cross-compilation is unsupported: host=$HOST_PLATFORM_ARCH target=$PLATFORM_ARCH" >&2
    exit 1
fi
if [ ! -d "$SRC_DIR" ] || [ ! -d "$INC_DIR" ]; then
    echo "Vendored libvterm source is missing under vendor/libvterm" >&2
    exit 1
fi

OUT_DIR="$SCRIPT_DIR/libvterm/lib/$PLATFORM_ARCH"
OUT_LIB="$OUT_DIR/libvterm.a"
mkdir -p "$OUT_DIR"

echo "Building libvterm for $PLATFORM_ARCH..."

# --- Determine CC flags ---
case "$PLATFORM_ARCH" in
    darwin_arm64)  ARCH_FLAG="-arch arm64" ;;
    darwin_amd64)  ARCH_FLAG="-arch x86_64" ;;
    linux_arm64|linux_amd64) ARCH_FLAG="" ;;
    *) echo "Unknown target: $PLATFORM_ARCH"; exit 1 ;;
esac

# --- Compile C sources ---
BUILD_TMP="$(mktemp -d)"
trap 'rm -rf "$BUILD_TMP"' EXIT

for f in "$SRC_DIR"/*.c; do
    # shellcheck disable=SC2086
    cc $ARCH_FLAG -O2 -I "$INC_DIR" -I "$SRC_DIR" -c "$f" -o "$BUILD_TMP/$(basename "${f%.c}").o"
done

# ZERO_AR_DATE stops ar writing a per-member mtime, which otherwise makes every
# build of identical source produce a different archive. The committed archives
# are checksummed in docs/provenance/third-party-artifacts.json and verified by
# scripts/check-repository-hygiene.py, so a non-reproducible build would mean
# that checksum only ever matched one machine at one instant: anyone rebuilding
# would fail the hygiene gate through no fault of their own.
ZERO_AR_DATE=1 ar rcs "$OUT_LIB" "$BUILD_TMP"/*.o
echo "Output: $OUT_LIB"
if command -v sha256sum >/dev/null 2>&1; then
    checksum="$(sha256sum "$OUT_LIB" | cut -d' ' -f1)"
elif command -v shasum >/dev/null 2>&1; then
    checksum="$(shasum -a 256 "$OUT_LIB" | cut -d' ' -f1)"
else
    echo "Neither sha256sum nor shasum is available" >&2
    exit 1
fi
echo "sha256: $checksum"
