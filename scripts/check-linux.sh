#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"

bash "$root/scripts/check-linux-dependencies.sh"
bash "$root/scripts/test.sh" -define:ODIN_TEST_THREADS=1
bash "$root/scripts/check.sh"

case "$(uname -m)" in
	x86_64|amd64) ;;
	aarch64|arm64)
		odin check "$root/accesskit" -collection:ingot="$root" -no-entry-point \
			-define:INGOT_ACCESSKIT=false
		;;
	*) echo "Unsupported Linux architecture: $(uname -m)" >&2; exit 1 ;;
esac

odin check "$root/accesskit" -collection:ingot="$root" -no-entry-point
odin check "$root/sys" -collection:ingot="$root" -no-entry-point
odin check "$root/pty" -collection:ingot="$root" -no-entry-point

if [ "${INGOT_LINUX_RUNTIME:-0}" = 1 ]; then
	command -v xvfb-run >/dev/null 2>&1 || {
		echo "xvfb-run is required for INGOT_LINUX_RUNTIME=1" >&2
		exit 1
	}
	WGPU_BACKEND=vulkan xvfb-run -a bash "$root/scripts/smoke-gallery.sh"
	WGPU_BACKEND=vulkan xvfb-run -a bash "$root/scripts/smoke-view-builder.sh"
fi

echo "Linux native gate: PASS"
