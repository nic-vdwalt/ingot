#!/usr/bin/env bash
# Cross-target type-check: vets every gated package for Windows x64, Linux x64
# and Linux arm64 from any host, so a platform `when` block or a `#+build`
# file cannot break a target the developer is not sitting on. It type-checks
# only; linking and running stay with the native gates in CI.
#
# Vendor libraries for the other targets are installed on first use by
# scripts/provision-cross-vendor.sh (needs the GitHub CLI once).
# Usage: scripts/check-cross.sh [extra odin flags...]
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/scripts/odin-toolchain.sh"
ingot_use_pinned_odin "$root"
col="-collection:ingot=$root"
manifest="$root/scripts/gate-manifest.json"
vet_flags="-vet -strict-style -vet-shadowing -no-entry-point"

manifest_values() {
	python3 -c 'import json,sys; data=json.load(open(sys.argv[1])); print(" ".join(data[sys.argv[2]]))' \
		"$manifest" "$1"
}

bash "$root/scripts/provision-cross-vendor.sh"

for target in windows_amd64 linux_amd64 linux_arm64; do
	for pkg in $(manifest_values check_packages); do
		# No prebuilt Box3D library exists for Linux arm64; its native gate
		# builds one from source (vendor/box3d/src/build.sh).
		if [ "$target" = linux_arm64 ] && [ "$pkg" = box3d_workers ]; then
			continue
		fi
		echo "== $target: checking $pkg =="
		# shellcheck disable=SC2086
		odin check "$root/$pkg" $col $vet_flags "-target:$target" "$@"
	done
	for pkg in $(manifest_values binding_packages); do
		echo "== $target: checking binding $pkg =="
		odin check "$root/$pkg" $col -no-entry-point "-target:$target" "$@"
	done
	if [ "$target" != linux_arm64 ]; then
		echo "== $target: checking gfx (INGOT_GFX_SDL3=true) =="
		# shellcheck disable=SC2086
		odin check "$root/gfx" $col $vet_flags "-target:$target" -define:INGOT_GFX_SDL3=true "$@"
	fi
done
echo "Cross-target type-check: PASS"
