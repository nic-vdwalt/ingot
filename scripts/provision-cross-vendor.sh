#!/usr/bin/env bash
# Install the prebuilt vendor libraries that `odin check -target:<os>` needs
# for Windows and Linux into the active Odin toolchain, so a macOS (or any)
# host can type-check those targets with scripts/check-cross.sh.
#
# A host toolchain only ships its own platform's vendor libraries, and Odin's
# vendor packages raise a compile-time panic when a target's library file is
# absent, even for `odin check`. The assets are the ones the CI workflows
# install (.github/workflows/*.yml), fetched with the GitHub CLI:
#   - the Windows Odin release: prebuilt stb and miniaudio .lib files
#   - wgpu-native v29.0.1.1: Windows x86_64, Linux x86_64 and Linux aarch64
#
# Idempotent: present libraries are left alone. Requires `gh auth login`.
# Usage: scripts/provision-cross-vendor.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/scripts/odin-toolchain.sh"
ingot_use_pinned_odin "$root"

ODIN_WINDOWS_ASSET=539931267
WGPU_WINDOWS_ASSET=455571718
WGPU_LINUX_X64_ASSET=455571719
WGPU_LINUX_ARM64_ASSET=455571722

odin_root="$(odin root)"
odin_root="${odin_root%/}"
vendor="$odin_root/vendor"
if [ ! -d "$vendor" ]; then
	echo "provision-cross-vendor: no vendor directory under $odin_root" >&2
	exit 1
fi
command -v unzip >/dev/null 2>&1 || {
	echo "provision-cross-vendor: unzip is required" >&2
	exit 1
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fetch() { # $1=repo, $2=asset id, $3=output file
	command -v gh >/dev/null 2>&1 || {
		echo "provision-cross-vendor: the GitHub CLI (gh) is required to download $1 asset $2" >&2
		exit 1
	}
	gh api "repos/$1/releases/assets/$2" -H "Accept: application/octet-stream" >"$3"
}

provision_wgpu() { # $1=asset id, $2=directory name, $3=library file name
	local dir="$vendor/wgpu/lib/$2"
	if [ -f "$dir/lib/$3" ]; then
		echo "wgpu $2: present"
		return
	fi
	echo "wgpu $2: downloading"
	fetch gfx-rs/wgpu-native "$1" "$work/$2.zip"
	mkdir -p "$dir"
	unzip -q -o "$work/$2.zip" -d "$dir"
	[ -f "$dir/lib/$3" ] || {
		echo "provision-cross-vendor: $2 archive did not contain lib/$3" >&2
		exit 1
	}
}

provision_windows_c_libs() {
	if [ -f "$vendor/stb/lib/stb_image.lib" ] && [ -f "$vendor/miniaudio/lib/miniaudio.lib" ]; then
		echo "stb/miniaudio windows: present"
		return
	fi
	echo "stb/miniaudio windows: downloading the Windows Odin release"
	fetch odin-lang/Odin "$ODIN_WINDOWS_ASSET" "$work/odin-windows.zip"
	unzip -q -o "$work/odin-windows.zip" '*/vendor/stb/lib/*.lib' \
		'*/vendor/miniaudio/lib/*.lib' -d "$work/odin-windows"
	local copied=0 lib relative
	while IFS= read -r lib; do
		relative="vendor/${lib#*/vendor/}"
		mkdir -p "$(dirname "$odin_root/$relative")"
		cp "$lib" "$odin_root/$relative"
		copied=$((copied + 1))
	done < <(find "$work/odin-windows" -name '*.lib' -type f)
	if [ "$copied" -eq 0 ]; then
		echo "provision-cross-vendor: the Windows release contained no vendor .lib files" >&2
		exit 1
	fi
	echo "stb/miniaudio windows: installed $copied libraries"
}

provision_windows_c_libs
provision_wgpu "$WGPU_WINDOWS_ASSET" wgpu-windows-x86_64-msvc-release wgpu_native.lib
provision_wgpu "$WGPU_LINUX_X64_ASSET" wgpu-linux-x86_64-release libwgpu_native.a
provision_wgpu "$WGPU_LINUX_ARM64_ASSET" wgpu-linux-aarch64-release libwgpu_native.a
echo "cross-target vendor libraries: ready in $vendor"
