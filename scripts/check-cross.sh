#!/usr/bin/env bash
# Cross-target type-check: vets every gated package for Windows x64, Linux x64
# and Linux arm64 from any host, so a platform `when` block or a `#+build`
# file cannot break a target the developer is not sitting on. It type-checks
# only; linking and running stay with the native gates in CI.
#
# Odin dev-2026-10 refuses `odin check -target:windows_amd64` on non-Windows
# hosts ("-windows-sdk-root:<path> must be used to target Windows") and only
# accepts that flag for `odin build`. Windows is therefore vetted with
# `odin build -build-mode:obj`, which runs the same checker and code generator
# but never invokes a linker, so no Windows SDK or lld-link is needed. The
# objects go to a scratch directory that is removed on exit.
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
scratch="$(mktemp -d "${TMPDIR:-/tmp}/ingot-check-cross.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

manifest_values() {
	python3 -c 'import json,sys; data=json.load(open(sys.argv[1])); print(" ".join(data[sys.argv[2]]))' \
		"$manifest" "$1"
}

# cross_check <target> <package path> [odin flags...]
cross_check() {
	local target="$1" pkg="$2"
	shift 2
	case "$target" in
	windows_*)
		rm -rf "$scratch/obj"
		mkdir -p "$scratch/obj"
		odin build "$pkg" "-target:$target" "-windows-sdk-root:$scratch" \
			-build-mode:obj "-out:$scratch/obj/pkg.obj" "$@"
		;;
	*)
		odin check "$pkg" "-target:$target" "$@"
		;;
	esac
}

bash "$root/scripts/provision-cross-vendor.sh"

for target in windows_amd64 linux_amd64 linux_arm64; do
	for pkg in $(manifest_values check_packages); do
		# No prebuilt Box3D library exists for Linux arm64; its native gate
		# builds one from source (vendor/box3d/src/build.sh).
		if [ "$target" = linux_arm64 ] && [ "$pkg" = examples/box3d_workers ]; then
			continue
		fi
		echo "== $target: checking $pkg =="
		# shellcheck disable=SC2086
		cross_check "$target" "$root/$pkg" $col $vet_flags "$@"
	done
	for pkg in $(manifest_values binding_packages); do
		echo "== $target: checking binding $pkg =="
		cross_check "$target" "$root/$pkg" $col -no-entry-point "$@"
	done
	if [ "$target" != linux_arm64 ]; then
		echo "== $target: checking gfx (INGOT_GFX_SDL3=true) =="
		# shellcheck disable=SC2086
		cross_check "$target" "$root/gfx" $col $vet_flags -define:INGOT_GFX_SDL3=true "$@"
	fi
done
echo "Cross-target type-check: PASS"
