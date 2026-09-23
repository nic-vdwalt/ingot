#!/usr/bin/env bash
# Sourced by the gate scripts: put the pinned Odin first on PATH.
#
# ingot_use_pinned_odin <root> [pin]
#
# The pin defaults to <root>/ODIN_VERSION; a consumer passes its own. When the
# odin already on PATH reports a different revision (Homebrew ships its own),
# look for the pinned compiler in $INGOT_ODIN_ROOT, then beside <root> in
# ../tools/odin-<release> (for example odin-dev-2026-08) or ../tools/odin-<rev>
# (for example odin-902106f), and prepend the first that reports the pin.
# Nothing changes when no pinned install is found; the toolchain check then
# reports the mismatch with the expected revision.

ingot_odin_reports() {
	local odin_bin="$1" pin="$2"
	"$odin_bin" version 2>/dev/null | tr ' ' '\n' | grep -qxF "$pin"
}

ingot_use_pinned_odin() {
	local root="$1" pin="${2:-}" release candidate current
	if [ -z "$pin" ]; then
		pin="$(tr -d '\r\n' < "$root/ODIN_VERSION")"
	fi
	current="$(command -v odin 2>/dev/null || true)"
	if [ -n "$current" ] && ingot_odin_reports "$current" "$pin"; then
		return 0
	fi
	release="${pin%%:*}"
	release="${release%-nightly}"
	for candidate in "${INGOT_ODIN_ROOT:-}" "$root/../tools/odin-$release" "$root/../tools/odin-${pin##*:}"; do
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
