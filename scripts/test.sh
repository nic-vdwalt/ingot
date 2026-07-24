#!/usr/bin/env bash
# Run the ingot test suite across all packages that have tests.
# Usage: scripts/test.sh [extra odin flags...]
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
col="-collection:ingot=$root"
"$root/scripts/check-ui-state.sh"
for pkg in gfx ui term prefs net; do
	echo "== testing $pkg =="
	extra=()
	# UI tests use deterministic single-thread execution for native graphics
	# fixtures and platform adapters.
	[ "$pkg" = ui ] && extra+=("-define:ODIN_TEST_THREADS=1")
	# term's pump fuzz needs the scripted PTY byte source (no shell spawned).
	[ "$pkg" = term ] && extra+=("-define:INGOT_PTY_SIM=true")
	odin test "$root/$pkg" $col -define:ODIN_TEST_FAIL_ON_EMPTY=true ${extra[@]+"${extra[@]}"} "$@"
done

# sys has no unit tests yet — type-check it so it can't rot.
for pkg in sys; do
	echo "== checking $pkg =="
	odin check "$root/$pkg" $col -no-entry-point
done
