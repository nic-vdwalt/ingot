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
#   fuzz/run.sh wsreconn       # WS reconnect state machine vs real worker thread
#                              # (sim transport via -define:INGOT_WS_SIM=true)
#   fuzz/run.sh tsan           # ThreadSanitizer pass over the threaded surfaces
#                              # (wsreconn + net tests + a11y queue stress);
#                              # ASan and TSan cannot share a binary, so this
#                              # is a separate phase, appended to each soak round
#   fuzz/run.sh gfx-frame      # WINDOWED GPU lifecycle fuzzer (needs a display;
#                              # NOT part of `all`/`soak` - run explicitly)
#   fuzz/run.sh all            # headless fuzzers + threaded TSan stress phase
#   fuzz/run.sh soak           # `all` for ROUNDS rounds with fresh seeds
#
# Sanitizer scope note: wgpu-native is a prebuilt release library, so ASan
# instruments the Odin side only; GPU-internal memory errors are outside its
# reach. gfx-frame compensates by building with -define:INGOT_GPU_STRICT=true
# so ANY wgpu validation message aborts the run.
#
# TSan scope note: term/pty are single-threaded by design (no reader threads;
# synchronous non-blocking PTY drains), so TSan there exercises nothing - the
# tsan target covers the only threaded code: the WS worker, the HTTP fetch
# pool, and the a11y action queue.
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
GUARD="-define:INGOT_FRAME_SCRATCH_GUARD=true"

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
	odin build "$ROOT/fuzz/net" $COL $GUARD $SANFLAGS -define:INGOT_NET_SIM=true -out:"$ROOT/fuzz/net/fuzz_net"
	"$ROOT/fuzz/net/fuzz_net" "$@"
}

run_ui() {
	# shellcheck disable=SC2086
	odin build "$ROOT/fuzz/ui" $COL $GUARD $SANFLAGS -out:"$ROOT/fuzz/ui/fuzz_ui"
	"$ROOT/fuzz/ui/fuzz_ui" "$@"
}

run_term() {
	# vt_bytes_for_key is package-private, so the term fuzzers live in-package
	# as tests (term/term_input_fuzz_test.odin), mirroring net/http_fuzz_test.odin.
	# INGOT_PTY_SIM scripts the PTY byte source so term_pump's drain/EOF loop
	# is fuzzed too; INGOT_FUZZ_ITER scales the pump fuzz past the test default.
	#
	# ODIN_TEST_THREADS=1 is required, not a preference: the pump fuzz drives
	# process-global PTY and libvterm state, so concurrent tests corrupt each
	# other's emulator. scripts/test.sh pins the same value for the same
	# reason; this runner previously omitted it.
	#
	# A seed replays a specific run: fuzz/run.sh term <seed>. The in-package
	# fuzzers take it as a compile-time define rather than as a runtime flag
	# like the standalone fuzz binaries, so this reads $SEED directly instead
	# of the pre-formatted ARGS array.
	local seed_define=()
	if [ -n "$SEED" ]; then
		seed_define=("-define:INGOT_FUZZ_SEED=$SEED")
	fi
	# shellcheck disable=SC2086
	odin test "$ROOT/term" $COL $GUARD $SANFLAGS -define:INGOT_PTY_SIM=true \
		-define:INGOT_FUZZ_ITER=3000 -define:ODIN_TEST_THREADS=1 \
		${seed_define[@]+"${seed_define[@]}"}
}

run_gfx_frame() {
	# Windowed: opens a real window + WebGPU device and interleaves resource
	# destruction (fonts, textures, render targets, UI rescale) inside live
	# frames - the destroy-before-submit bug class that headless tests can't
	# reach. Built without a sanitizer flag override is fine, but ASan works.
	# INGOT_GPU_STRICT aborts on any wgpu validation message (see header).
	# shellcheck disable=SC2086
	odin build "$ROOT/fuzz/gfx_frame" $COL $GUARD $SANFLAGS -define:INGOT_GPU_STRICT=true -out:"$ROOT/fuzz/gfx_frame/fuzz_gfx_frame"
	"$ROOT/fuzz/gfx_frame/fuzz_gfx_frame" "$@"
}

run_interact() {
	# Headless widget interaction fuzzer: drives real widgets with random
	# synthetic input sequences (INGOT_INPUT_SIM seam) and checks routing,
	# focus, latch, and semantic-buffer invariants.
	# shellcheck disable=SC2086
	odin build "$ROOT/fuzz/interact" $COL $GUARD $SANFLAGS -define:INGOT_INPUT_SIM=true -out:"$ROOT/fuzz/interact/fuzz_interact"
	"$ROOT/fuzz/interact/fuzz_interact" "$@"
}

run_input() {
	# Text-input edit-op fuzzer lives in-package (edit machinery is private),
	# mirroring the term pattern; INGOT_FUZZ_ITER scales the op count far past
	# the fast default used by scripts/test.sh.
	# shellcheck disable=SC2086
	odin test "$ROOT/ui" $COL $GUARD $SANFLAGS -define:ODIN_TEST_THREADS=1 -define:INGOT_FUZZ_ITER=200000
}

run_wsreconn() {
	# Reconnect state-machine fuzzer: real worker thread + scripted transport.
	# shellcheck disable=SC2086
	odin build "$ROOT/fuzz/wsreconn" $COL $GUARD $SANFLAGS -define:INGOT_WS_SIM=true -out:"$ROOT/fuzz/wsreconn/fuzz_wsreconn"
	"$ROOT/fuzz/wsreconn/fuzz_wsreconn" "$@"
}

run_tsan() {
	# ThreadSanitizer phase (separate binaries - TSan and ASan don't compose).
	local TS="-debug -sanitize:thread"
	# shellcheck disable=SC2086
	odin build "$ROOT/fuzz/wsreconn" $COL $TS -define:INGOT_WS_SIM=true -out:"$ROOT/fuzz/wsreconn/fuzz_wsreconn_tsan"
	"$ROOT/fuzz/wsreconn/fuzz_wsreconn_tsan" "$@"
	# Native eight-worker fetch pool: deterministic transport stresses parked
	# condvar wakeups, result publication/wake hooks, partial sends, allocator
	# ownership, and prompt broadcast shutdown under TSan.
	# shellcheck disable=SC2086
	odin test "$ROOT/net" $COL $TS -define:INGOT_HTTP_STRESS=true -define:ODIN_TEST_THREADS=1
	# a11y action queue: threaded producer vs main-thread drain (in gfx,
	# where the queue lives).
	# shellcheck disable=SC2086
	odin test "$ROOT/gfx" $COL $TS -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=gfx.a11y_action_queue_stress
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
wsreconn)
	run_wsreconn "${ARGS[@]+"${ARGS[@]}"}"
	;;
tsan)
	run_tsan "${ARGS[@]+"${ARGS[@]}"}"
	;;
all)
	run_net "${ARGS[@]+"${ARGS[@]}"}"
	run_ui "${ARGS[@]+"${ARGS[@]}"}"
	run_interact "${ARGS[@]+"${ARGS[@]}"}"
	run_wsreconn "${ARGS[@]+"${ARGS[@]}"}"
	run_input
	run_term
	run_tsan "${ARGS[@]+"${ARGS[@]}"}"
	;;
soak)
	# Multi-round soak: each round uses a fresh random seed so repeated CI
	# runs cover different input space instead of replaying one trajectory.
	# Any failure prints the exact repro command and aborts.
	ROUNDS="${ROUNDS:-10}"
	for round in $(seq 1 "$ROUNDS"); do
		round_seed="$(od -An -N8 -tu8 /dev/urandom | tr -d ' ')"
		echo "=== soak round $round/$ROUNDS seed=$round_seed ==="
		for harness in net ui interact wsreconn; do
			if ! "run_$harness" "-seed:$round_seed" "${ITERATIONS:+-iterations:$ITERATIONS}"; then
				echo "SOAK FAILED - reproduce with: fuzz/run.sh $harness $round_seed" >&2
				exit 1
			fi
		done
		if ! run_input; then
			echo "SOAK FAILED in input fuzz tests (rerun: fuzz/run.sh input)" >&2
			exit 1
		fi
		if ! run_term; then
			echo "SOAK FAILED in term tests (deterministic seeds - rerun: fuzz/run.sh term)" >&2
			exit 1
		fi
		if ! run_tsan "-seed:$round_seed"; then
			echo "SOAK FAILED in TSan phase - reproduce with: fuzz/run.sh tsan $round_seed" >&2
			exit 1
		fi
	done
	;;
*)
	echo "unknown target '$TARGET' (expected net|ui|term|interact|input|wsreconn|tsan|gfx-frame|all|soak)" >&2
	exit 2
	;;
esac
