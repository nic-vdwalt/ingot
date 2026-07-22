#!/usr/bin/env bash
# Run the ingot test suite across all packages that have tests.
# Usage: scripts/test.sh [extra odin flags...]
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
col="-collection:ingot=$root"
for pkg in gfx ui term prefs net; do
	echo "== testing $pkg =="
	extra=()
	# ui widgets share module-level scratch state (measure backend, route
	# claims, overlay recorder); run its tests on one thread so global
	# installs/resets from one test can't race another.
	[ "$pkg" = ui ] && extra+=("-define:ODIN_TEST_THREADS=1")
	odin test "$root/$pkg" $col -define:ODIN_TEST_FAIL_ON_EMPTY=true ${extra[@]+"${extra[@]}"} "$@"
done

# sys has no unit tests yet — type-check it so it can't rot.
for pkg in sys; do
	echo "== checking $pkg =="
	odin check "$root/$pkg" $col -no-entry-point
done
