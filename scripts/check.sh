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

for pkg in gfx ui ui_gfx term prefs net sys pty testx; do
	echo "== checking $pkg =="
	# shellcheck disable=SC2086
	odin check "$root/$pkg" $col $vet_flags "$@"
done

# Foreign bindings intentionally mirror upstream names and declarations, but
# they must still type-check against the pinned toolchain.
for pkg in libvterm accesskit; do
	echo "== checking binding $pkg =="
	odin check "$root/$pkg" $col -no-entry-point "$@"
done

# odinfmt has no list/check flag (only -w/-stdin), so compare each file
# against its formatted output. Formatting is part of the strict gate.
if ! command -v odinfmt >/dev/null 2>&1; then
	echo "odinfmt not found on PATH. Install the version bundled with the pinned Odin toolchain." >&2
	exit 1
fi

echo "== odinfmt (verify formatting) =="
unformatted=0
while IFS= read -r f; do
	if ! odinfmt "$root/$f" 2>/dev/null | cmp -s "$root/$f" -; then
		echo "needs formatting: $f" >&2
		unformatted=1
	fi
done < <(cd "$root" && git ls-files '*.odin')
if [[ $unformatted -ne 0 ]]; then
	echo "Some files are not formatted. Run: odinfmt -w $root" >&2
	exit 1
fi
