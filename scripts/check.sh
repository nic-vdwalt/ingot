#!/usr/bin/env bash
# Tiger Style gate for ingot: strict type-check + vet across every package.
# This is our "lint" — odin has no separate linter, so -vet -strict-style is it.
# Usage: scripts/check.sh [extra odin flags...]
# See docs/TIGER_STYLE.md.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
col="-collection:ingot=$root"

# Type-check + vet every package. -vet-shadowing and -strict-style turn sloppy
# code into build failures; -no-entry-point lets us check library packages that
# have no main().
vet_flags="-vet -strict-style -vet-shadowing -no-entry-point"

for pkg in gfx ui term prefs net sys; do
	echo "== checking $pkg =="
	# shellcheck disable=SC2086
	odin check "$root/$pkg" $col $vet_flags "$@"
done

# Format check (non-fatal if odinfmt is unavailable). Run `odinfmt -w .` to fix.
if command -v odinfmt >/dev/null 2>&1; then
	echo "== odinfmt -l (report files needing formatting) =="
	odinfmt -l "$root" || {
		echo "Some files are not formatted. Run: odinfmt -w $root" >&2
		exit 1
	}
else
	echo "odinfmt not found on PATH — skipping format check." >&2
fi
