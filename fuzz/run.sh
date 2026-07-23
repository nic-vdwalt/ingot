#!/usr/bin/env bash
# Build and run the ingot memory-safety fuzz harnesses under a sanitizer
# with a tracking allocator (leaks / bad frees fail the run).
#
# Usage: fuzz/run.sh [net|ui|term|interact|input|gfx-frame|all|soak] [seed] [iterations]
#   fuzz/run.sh net            # random seed, default iterations
#   fuzz/run.sh net 12345      # reproduce a specific seed
#   fuzz/run.sh term           # in-package fuzz tests (private procs) via odin test
#   fuzz/run.sh interact       # widget interaction-sequence fuzzer (headless,
#                              # synthetic input via -define:INGOT_INPUT_SIM=true)
#   fuzz/run.sh input          # text-input edit-op fuzzer (in-package, high iterations)
#   fuzz/run.sh gfx-frame      # WINDOWED GPU lifecycle fuzzer (needs a display;
#                              # NOT part of `all`/`soak` — run explicitly)
#   fuzz/run.sh all            # net + ui + term + interact + input (headless only)
#   fuzz/run.sh soak           # `all` for ROUNDS rounds with fresh seeds
#
# Sanitizer scope note: wgpu-native is a prebuilt release library, so ASan
# instruments the Odin side only; GPU-internal memory errors are outside its
# reach. gfx-frame compensates by building with -define:INGOT_GPU_STRICT=true
# so ANY wgpu validation message aborts the run.
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

run_gfx_frame() {
	# Windowed: opens a real window + WebGPU device and interleaves resource
	# destruction (fonts, textures, render targets, UI rescale) inside live
	# frames — the destroy-before-submit bug class that headless tests can't
	# reach. Built without a sanitizer flag override is fine, but ASan works.
	# INGOT_GPU_STRICT aborts on any wgpu validation message (see header).
	# shellcheck disable=SC2086
	odin build "$ROOT/fuzz/gfx_frame" $COL $SANFLAGS -define:INGOT_GPU_STRICT=true -out:"$ROOT/fuzz/gfx_frame/fuzz_gfx_frame"
	"$ROOT/fuzz/gfx_frame/fuzz_gfx_frame" "$@"
}

run_interact() {
	# Headless widget interaction fuzzer: drives real widgets with random
	# synthetic input sequences (INGOT_INPUT_SIM seam) and checks routing,
	# focus, latch, and semantic-buffer invariants.
	# shellcheck disable=SC2086
	odin build "$ROOT/fuzz/interact" $COL $SANFLAGS -define:INGOT_INPUT_SIM=true -out:"$ROOT/fuzz/interact/fuzz_interact"
	"$ROOT/fuzz/interact/fuzz_interact" "$@"
}

run_input() {
	# Text-input edit-op fuzzer lives in-package (edit machinery is private),
	# mirroring the term pattern; INGOT_FUZZ_ITER scales the op count far past
	# the fast default used by scripts/test.sh.
	# shellcheck disable=SC2086
	odin test "$ROOT/ui" $COL $SANFLAGS -define:ODIN_TEST_THREADS=1 -define:INGOT_FUZZ_ITER=200000
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
gfx-frame)
	run_gfx_frame "${ARGS[@]+"${ARGS[@]}"}"
	;;
interact)
	run_interact "${ARGS[@]+"${ARGS[@]}"}"
	;;
input)
	run_input
	;;
all)
	run_net "${ARGS[@]+"${ARGS[@]}"}"
	run_ui "${ARGS[@]+"${ARGS[@]}"}"
	run_interact "${ARGS[@]+"${ARGS[@]}"}"
	run_input
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
		for harness in net ui interact; do
			if ! "run_$harness" "-seed:$round_seed" "${ITERATIONS:+-iterations:$ITERATIONS}"; then
				echo "SOAK FAILED — reproduce with: fuzz/run.sh $harness $round_seed" >&2
				exit 1
			fi
		done
		if ! run_input; then
			echo "SOAK FAILED in input fuzz tests (rerun: fuzz/run.sh input)" >&2
			exit 1
		fi
		if ! run_term; then
			echo "SOAK FAILED in term tests (deterministic seeds — rerun: fuzz/run.sh term)" >&2
			exit 1
		fi
	done
	;;
*)
	echo "unknown target '$TARGET' (expected net|ui|term|interact|input|gfx-frame|all|soak)" >&2
	exit 2
	;;
esac
