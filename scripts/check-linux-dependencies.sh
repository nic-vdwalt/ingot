#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
errors=0
sdl_backend=0
for argument in "$@"; do
	if [ "$argument" = "-define:INGOT_GFX_SDL3=true" ]; then
		sdl_backend=1
	fi
done

fail() {
	echo "linux dependency: $1" >&2
	errors=$((errors + 1))
}

if [ "$(uname -s)" != "Linux" ]; then
	fail "this gate must run on a Linux host; cross-compilation is unsupported"
fi

for command in odin odinfmt python3 cc ar pkg-config; do
	command -v "$command" >/dev/null 2>&1 || fail "$command is required on PATH"
done

if command -v odin >/dev/null 2>&1; then
	expected="$(tr -d '\r\n' < "$root/ODIN_VERSION")"
	actual="$(odin version | awk '{print $NF}')"
	[ "$actual" = "$expected" ] || fail "Odin mismatch: expected $expected, got $actual"

	odin_root="$(dirname "$(dirname "$(command -v odin)")")"
	wgpu_archive="$(find "$odin_root" -path '*vendor/wgpu/lib/wgpu-linux-*-release/lib/libwgpu_native.a' -print -quit 2>/dev/null || true)"
	[ -n "$wgpu_archive" ] || fail "the pinned Odin installation lacks the Linux wgpu-native archive"
fi

if command -v pkg-config >/dev/null 2>&1; then
	pkg-config --exists libcurl || fail "libcurl development files are required"
	pkg-config --exists vulkan || fail "Vulkan loader development files are required"
	x11_ok=0
	for package in x11 xrandr xi xtst xcursor xinerama xscrnsaver; do
		if ! pkg-config --exists "$package"; then
			fail "$package development files are required by native GLFW/SDL3 X11"
			x11_ok=1
		fi
	done
	[ "$x11_ok" -eq 0 ] || true
	if [ "$sdl_backend" -eq 1 ]; then
		pkg-config --exists sdl3 || fail "SDL3 development files are required by INGOT_GFX_SDL3"
	fi
fi

case "$(uname -m)" in
	x86_64|amd64) platform_arch="linux_amd64" ;;
	aarch64|arm64) platform_arch="linux_arm64" ;;
	*) fail "unsupported Linux architecture: $(uname -m)"; platform_arch="" ;;
esac

if [ -n "$platform_arch" ]; then
	libvterm="$root/libvterm/lib/$platform_arch/libvterm.a"
	if [ ! -f "$libvterm" ]; then
		echo "Building $platform_arch libvterm from pinned vendored source..."
		bash "$root/scripts/build-libvterm.sh" --target "$platform_arch"
	fi
	[ -f "$libvterm" ] || fail "libvterm archive is unavailable for $platform_arch"
fi

for helper in xdg-open zenity kdialog; do
	if ! command -v "$helper" >/dev/null 2>&1; then
		echo "linux optional: $helper is unavailable" >&2
	fi
done

if [ "$errors" -ne 0 ]; then
	echo "$errors required Linux dependency check(s) failed" >&2
	exit 1
fi

echo "Linux dependencies: PASS"
