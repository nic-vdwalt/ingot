#!/usr/bin/env bash
# Sourced by the gate scripts: put the pinned Odin first on PATH.
#
# ODIN_VERSION names one exact compiler. When the odin already on PATH is a
# different one (Homebrew ships its own revision), look for the pinned release
# in $INGOT_ODIN_ROOT, then ../tools/odin-<release> beside this checkout, and
# prepend the first one that reports the pinned revision. Nothing is changed
# when no pinned install is found; scripts/check-toolchain.py then reports the
# mismatch with the expected revision.

ingot_odin_reports() {
	local odin_bin="$1" pin="$2"
	"$odin_bin" version 2>/dev/null | tr ' ' '\n' | grep -qxF "$pin"
}

ingot_use_pinned_odin() {
	local root="$1" pin release candidate current
	pin="$(tr -d '\r\n' < "$root/ODIN_VERSION")"
	current="$(command -v odin 2>/dev/null || true)"
	if [ -n "$current" ] && ingot_odin_reports "$current" "$pin"; then
		return 0
	fi
	release="${pin%%:*}"
	release="${release%-nightly}"
	for candidate in "${INGOT_ODIN_ROOT:-}" "$root/../tools/odin-$release"; do
		[ -n "$candidate" ] && [ -x "$candidate/odin" ] || continue
		if ingot_odin_reports "$candidate/odin" "$pin"; then
			candidate="$(cd "$candidate" && pwd)"
			export PATH="$candidate:$PATH"
			echo "using pinned Odin $pin from $candidate" >&2
			return 0
		fi
	done
	return 0
}
