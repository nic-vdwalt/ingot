#!/usr/bin/env bash
# Build and run the ingot memory-safety fuzz harnesses under AddressSanitizer
# with a tracking allocator (leaks / bad frees fail the run).
#
# Usage: fuzz/run.sh [net|ui|term] [seed] [iterations]
#   fuzz/run.sh net            # random seed, default iterations
#   fuzz/run.sh net 12345      # reproduce a specific seed
#   fuzz/run.sh term           # in-package fuzz tests (private procs) via odin test
#
# net is built with -define:INGOT_NET_SIM=true so the simulated transport's
# clone/deliver/free cycle is exercised alongside the response parser.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-net}"
SEED="${2:-}"
ITERATIONS="${3:-}"
COL="-collection:ingot=$ROOT"
SAN="-debug -sanitize:address"

ARGS=()
[ -n "$SEED" ] && ARGS+=("-seed:$SEED")
[ -n "$ITERATIONS" ] && ARGS+=("-iterations:$ITERATIONS")

case "$TARGET" in
net)
	# shellcheck disable=SC2086
	odin build "$ROOT/fuzz/net" $COL $SAN -define:INGOT_NET_SIM=true -out:"$ROOT/fuzz/net/fuzz_net"
	"$ROOT/fuzz/net/fuzz_net" "${ARGS[@]+"${ARGS[@]}"}"
	;;
ui)
	# shellcheck disable=SC2086
	odin build "$ROOT/fuzz/ui" $COL $SAN -out:"$ROOT/fuzz/ui/fuzz_ui"
	"$ROOT/fuzz/ui/fuzz_ui" "${ARGS[@]+"${ARGS[@]}"}"
	;;
term)
	# vt_bytes_for_key is package-private, so the term fuzzers live in-package
	# as tests (term/term_input_fuzz_test.odin), mirroring net/http_fuzz_test.odin.
	# shellcheck disable=SC2086
	odin test "$ROOT/term" $COL $SAN
	;;
*)
	echo "unknown target '$TARGET' (expected net|ui|term)" >&2
	exit 2
	;;
esac
