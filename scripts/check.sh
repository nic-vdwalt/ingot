#!/usr/bin/env bash
# Tiger Style gate for ingot: strict type-check + vet across every package.
# This is our "lint" - odin has no separate linter, so -vet -strict-style is it.
# Usage: scripts/check.sh [extra odin flags...]
# See docs/TIGER_STYLE.md.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
col="-collection:ingot=$root"

echo "== Odin toolchain =="
PYTHONDONTWRITEBYTECODE=1 python3 "$root/scripts/check_toolchain_test.py"
PYTHONDONTWRITEBYTECODE=1 python3 "$root/scripts/check-toolchain.py"

# Type-check + vet every package. -vet-shadowing and -strict-style turn sloppy
# code into build failures; -no-entry-point lets us check library packages that
# have no main().
vet_flags="-vet -strict-style -vet-shadowing -no-entry-point"

echo "== repository hygiene =="
PYTHONDONTWRITEBYTECODE=1 python3 "$root/scripts/check-repository-hygiene.py"

echo "== gfx context ownership guard =="
PYTHONDONTWRITEBYTECODE=1 python3 "$root/scripts/check_gfx_context_test.py"
PYTHONDONTWRITEBYTECODE=1 python3 "$root/scripts/check_gfx_context.py" \
	--baseline "$root/scripts/gfx_context_baseline.json" \
	"$root"

echo "== assertion discipline =="
PYTHONDONTWRITEBYTECODE=1 python3 "$root/scripts/check_assertions_test.py"
PYTHONDONTWRITEBYTECODE=1 python3 "$root/scripts/check_assertions.py" \
	--baseline "$root/scripts/assertion_baseline.json" \
	"$root"

echo "== UI API layers =="
PYTHONDONTWRITEBYTECODE=1 python3 "$root/scripts/check_ui_api_layers_test.py"
PYTHONDONTWRITEBYTECODE=1 python3 "$root/scripts/check_ui_api_layers.py" "$root"

for pkg in gfx ui ui_gfx term prefs net sys pty testx; do
	echo "== checking $pkg =="
	# shellcheck disable=SC2086
	odin check "$root/$pkg" $col $vet_flags "$@"
done

# Simulated-transport builds are a separate compilation of the same packages:
# a `when !INGOT_*_SIM` block hides code from one mode and reveals it in the
# other, so a default-mode check cannot see breakage in the sim mode. This is
# checked in test mode because the gap that motivated it was a test file
# referencing procedures that only exist in the real-transport build, which
# silently disabled every simulated-transport test and the net fuzzer.
for spec in \
	"net:INGOT_NET_SIM=true" \
	"net:INGOT_WS_SIM=true" \
	"pty:INGOT_PTY_SIM=true" \
	"term:INGOT_PTY_SIM=true" \
	"gfx:INGOT_INPUT_SIM=true"; do
	pkg="${spec%%:*}"
	define="${spec#*:}"
	echo "== checking $pkg ($define) =="
	# ODIN_TEST_NAMES selects no test, so this compiles the test build without
	# running it.
	odin test "$root/$pkg" $col "-define:$define" \
		-define:ODIN_TEST_NAMES=__compile_only__ >/dev/null
done

# Foreign bindings intentionally mirror upstream names and declarations, but
# they must still type-check against the pinned toolchain.
for pkg in libvterm accesskit; do
	echo "== checking binding $pkg =="
	odin check "$root/$pkg" $col -no-entry-point "$@"
done

# Examples are consumer contracts, not samples that may rot independently.
# Build every example because a public config struct gaining a field can keep
# all library packages green while breaking every real application.
example_out="${TMPDIR:-/tmp}/ingot-example-check"
mkdir -p "$example_out"
for example in \
	hello \
	gallery \
	breakout \
	idle_demo \
	chart_demo \
	render_fixture \
	multi_context_fixture \
	raylib_migration_fixture; do
	echo "== building example $example =="
	odin build "$root/examples/$example" $col "-out:$example_out/$example" "$@"
done

echo "== Odin physical style limits =="
PYTHONDONTWRITEBYTECODE=1 python3 "$root/scripts/check_odin_style_test.py"
PYTHONDONTWRITEBYTECODE=1 python3 "$root/scripts/check_odin_style.py" \
	--baseline "$root/scripts/odin_style_baseline.json" \
	"$root"

# The guard itself runs in check-web.sh against a freshly built module; its
# unit tests belong here with the other script tests, so a broken parser
# cannot silently pass every wasm it is handed.
echo "== wasm bloat guard tests =="
PYTHONDONTWRITEBYTECODE=1 python3 "$root/scripts/check_wasm_bloat_test.py"

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
