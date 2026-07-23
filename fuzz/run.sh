#!/usr/bin/env bash
# Build and run the ingot memory-safety fuzz harnesses under a sanitizer
# with a tracking allocator (leaks / bad frees fail the run).
#
# Usage: fuzz/run.sh [net|ui|term|all|soak] [seed] [iterations]
#   fuzz/run.sh net            # random seed, default iterations
#   fuzz/run.sh net 12345      # reproduce a specific seed
#   fuzz/run.sh term           # in-package fuzz tests (private procs) via odin test
#   fuzz/run.sh all            # net + ui + term sequentially
#   fuzz/run.sh soak           # `all` for ROUNDS rounds with fresh seeds
#
# Environment:
#   SAN=address|thread|none    # sanitizer (default: address).
#                              # MemorySanitizer is unavailable on darwin;
#                              # run MSan on a Linux host if needed.
#   ROUNDS=N                   # soak rounds (default: 10)
#
# net is built with -define:INGOT_NET_SIM=true so the simulated transport's
# clone/deliver/free cycle is exercised alongside the response parser.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-net}"
SEED="${2:-}"
ITERATIONS="${3:-}"
COL="-collection:ingot=$ROOT"

case "${SAN:-address}" in
address) SANFLAGS="-debug -sanitize:address" ;;
thread) SANFLAGS="-debug -sanitize:thread" ;;
none) SANFLAGS="-debug" ;;
*)
	echo "unknown SAN '$SAN' (expected address|thread|none)" >&2
	exit 2
	;;
esac

ARGS=()
[ -n "$SEED" ] && ARGS+=("-seed:$SEED")
[ -n "$ITERATIONS" ] && ARGS+=("-iterations:$ITERATIONS")

run_net() {
	# shellcheck disable=SC2086
	odin build "$ROOT/fuzz/net" $COL $SANFLAGS -define:INGOT_NET_SIM=true -out:"$ROOT/fuzz/net/fuzz_net"
	"$ROOT/fuzz/net/fuzz_net" "$@"
}

run_ui() {
	# shellcheck disable=SC2086
	odin build "$ROOT/fuzz/ui" $COL $SANFLAGS -out:"$ROOT/fuzz/ui/fuzz_ui"
	"$ROOT/fuzz/ui/fuzz_ui" "$@"
}

run_term() {
	# vt_bytes_for_key is package-private, so the term fuzzers live in-package
	# as tests (term/term_input_fuzz_test.odin), mirroring net/http_fuzz_test.odin.
	# shellcheck disable=SC2086
	odin test "$ROOT/term" $COL $SANFLAGS
}

case "$TARGET" in
net)
	run_net "${ARGS[@]+"${ARGS[@]}"}"
	;;
ui)
	run_ui "${ARGS[@]+"${ARGS[@]}"}"
	;;
term)
	run_term
	;;
all)
	run_net "${ARGS[@]+"${ARGS[@]}"}"
	run_ui "${ARGS[@]+"${ARGS[@]}"}"
	run_term
	;;
soak)
	# Multi-round soak: each round uses a fresh random seed so repeated CI
	# runs cover different input space instead of replaying one trajectory.
	# Any failure prints the exact repro command and aborts.
	ROUNDS="${ROUNDS:-10}"
	for round in $(seq 1 "$ROUNDS"); do
		round_seed="$(od -An -N8 -tu8 /dev/urandom | tr -d ' ')"
		echo "=== soak round $round/$ROUNDS seed=$round_seed ==="
		for harness in net ui; do
			if ! "run_$harness" "-seed:$round_seed" "${ITERATIONS:+-iterations:$ITERATIONS}"; then
				echo "SOAK FAILED — reproduce with: fuzz/run.sh $harness $round_seed" >&2
				exit 1
			fi
		done
		if ! run_term; then
			echo "SOAK FAILED in term tests (deterministic seeds — rerun: fuzz/run.sh term)" >&2
			exit 1
		fi
	done
	;;
*)
	echo "unknown target '$TARGET' (expected net|ui|term|all|soak)" >&2
	exit 2
	;;
esac
