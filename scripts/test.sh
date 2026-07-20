#!/usr/bin/env bash
# Run the ingot test suite across all packages that have tests.
# Usage: scripts/test.sh [extra odin flags...]
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
col="-collection:ingot=$root"
for pkg in gfx ui term prefs; do
	echo "== testing $pkg =="
	odin test "$root/$pkg" $col -define:ODIN_TEST_FAIL_ON_EMPTY=true "$@"
done

# net/sys have no unit tests yet — type-check them so they can't rot.
for pkg in net sys; do
	echo "== checking $pkg =="
	odin check "$root/$pkg" $col -no-entry-point
done
