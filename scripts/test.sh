#!/usr/bin/env bash
# Run the ingot test suite across all packages that have tests.
# Usage: scripts/test.sh [extra odin flags...]
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
col="-collection:ingot=$root"
guard="-define:INGOT_FRAME_SCRATCH_GUARD=true"
timeout_seconds="${INGOT_TEST_TIMEOUT_SECONDS:-300}"
output_limit_bytes="${INGOT_TEST_OUTPUT_LIMIT_BYTES:-16777216}"
log_dir="${INGOT_TEST_FAILURE_LOG_DIR:-${TMPDIR:-/tmp}/ingot-test-failures}"
supervisor="$root/scripts/test-supervisor.py"

if [ "$(uname -s)" = "Linux" ]; then
	bash "$root/scripts/check-linux-dependencies.sh"
fi

require_positive_integer() {
	local name="$1"
	local value="$2"
	if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
		echo "$name must be a positive integer, got: $value" >&2
		exit 2
	fi
}

run_supervised() {
	local pkg="$1"
	shift
	python3 "$supervisor" \
		--package "$pkg" \
		--timeout "$timeout_seconds" \
		--output-limit "$output_limit_bytes" \
		--log-dir "$log_dir" \
		-- "$@"
}

require_positive_integer INGOT_TEST_TIMEOUT_SECONDS "$timeout_seconds"
require_positive_integer INGOT_TEST_OUTPUT_LIMIT_BYTES "$output_limit_bytes"
"$root/scripts/check-ui-state.sh"
PYTHONDONTWRITEBYTECODE=1 python3 "$root/scripts/check_gfx_context.py" \
	--baseline "$root/scripts/gfx_context_baseline.json" \
	"$root"
has_define() {
	local wanted="$1"
	shift
	local arg
	for arg in "$@"; do
		[[ "$arg" == "-define:$wanted="* ]] && return 0
	done
	return 1
}

for pkg in asset box3d_workers ecs gfx procgen scene scene_gfx ui ui_gfx fit view view/generate libvterm term prefs net; do
	echo "== testing $pkg =="
	extra=()
	# UI tests use deterministic single-thread execution for native graphics
	# fixtures and platform adapters unless the caller chose another value.
	if [ "$pkg" = ui ] && ! has_define ODIN_TEST_THREADS "$@"; then
		extra+=("-define:ODIN_TEST_THREADS=1")
	fi
	# term's pump fuzz uses process-global PTY and libvterm state, so its tests
	# must not execute concurrently.
	if [ "$pkg" = term ]; then
		if ! has_define INGOT_PTY_SIM "$@"; then
			extra+=("-define:INGOT_PTY_SIM=true")
		fi
		if ! has_define ODIN_TEST_THREADS "$@"; then
			extra+=("-define:ODIN_TEST_THREADS=1")
		fi
	fi
	# The supervisor names its failure log after the label, so a nested package
	# path has to be flattened: "view/generate" would otherwise write into a
	# directory that does not exist.
	run_supervised "${pkg//\//-}" odin test "$root/$pkg" "$col" "$guard" \
		-define:ODIN_TEST_FAIL_ON_EMPTY=true ${extra[@]+"${extra[@]}"} "$@"
done

echo "== testing examples/box3d_advanced =="
run_supervised "box3d-advanced-example" odin test "$root/examples/box3d_advanced" "$col" \
	"$guard" -define:ODIN_TEST_FAIL_ON_EMPTY=true "$@"

echo "== testing native WSS loopback TLS =="
run_supervised "wss-loopback" python3 "$root/scripts/wss-loopback-test.py" \
	--fixture "$root/examples/wss_fixture" "--collection=$col"

# Packages without unit tests are still type-checked so they cannot rot.
for pkg in sys pty accesskit testx; do
	echo "== checking $pkg =="
	run_supervised "$pkg-check" odin check "$root/$pkg" "$col" -no-entry-point
done
