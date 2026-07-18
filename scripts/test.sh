#!/usr/bin/env bash
# Run the ingot test suite across all packages that have tests.
# Usage: scripts/test.sh [extra odin flags...]
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
col="-collection:ingot=$root"
for pkg in ui term prefs; do
	echo "== testing $pkg =="
	odin test "$root/$pkg" $col -define:ODIN_TEST_FAIL_ON_EMPTY=true "$@"
done
