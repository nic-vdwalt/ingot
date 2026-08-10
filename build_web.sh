#!/usr/bin/env bash
# Build the ingot WebGPU browser demo (Odin -> wasm) and stage the web/ dir.
#
# Output: web/ingot_web.wasm plus the Odin + wgpu JS runtimes copied in. Serve
# the web/ directory with any static HTTP server and open index.html in a
# WebGPU-capable browser (Chrome/Edge 113+, Safari 18+).
#
#   bash build_web.sh && (cd web && python3 -m http.server 8000)
#   open http://localhost:8000
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
WEB="$ROOT/web"

# The staged odin.js is copied out of the toolchain that compiled the module,
# so the two must come from the same Odin. Homebrew's odin and the pinned
# checkout ship different copies of core/sys/wasm/js/odin.js, and building
# against the wrong one yields a demo that boots locally and then fails in the
# browser in ways that read like an engine bug.
#
# This is deliberately weaker than scripts/check-toolchain.py, which check.sh
# and CI run: a locally built odin reports its version as "dev-2026-08" with no
# revision, so a strict comparison rejects the CORRECT toolchain. Only a
# toolchain that names a revision AND disagrees with the pin is provably wrong,
# and that is exactly the Homebrew case this guards against. When no revision
# is reported the build proceeds and says so, because refusing to build on
# absent evidence would stop the pinned checkout working at all.
assert_toolchain() {
	local pin actual revision
	pin="$(tr -d '\r\n' < "$ROOT/ODIN_VERSION")"
	if ! actual="$(odin version 2>&1)"; then
		echo "error: odin not found on PATH; expected $pin" >&2
		exit 1
	fi
	revision="$(printf '%s' "$actual" | tr ' ' '\n' | grep '^dev-[0-9-]*:' || true)"
	if [ -z "$revision" ]; then
		echo "warning: odin did not report a revision, cannot verify the $pin pin"
		return 0
	fi
	if [ "$revision" != "$pin" ]; then
		echo "error: Odin toolchain mismatch: expected $pin, got $revision" >&2
		echo "       put the pinned checkout first on PATH, e.g." >&2
		echo "       PATH=\"/path/to/odin-box3d-workers:\$PATH\" bash build_web.sh ..." >&2
		exit 1
	fi
	echo "Odin toolchain: $revision"
}
assert_toolchain

# A threaded build needs more than an Odin that matches the pin: it needs the
# box3d vendor that can supply a threaded object. assert_toolchain above cannot
# see that difference, and the failure mode when it is missing is remote from
# the cause - vendor/box3d/box3d.odin without the BOX3D_WASM_THREADS selector
# silently links the SINGLE-threaded lib/box3d_wasm.o, whose finishTask runs
# inline on the calling thread, while -target-features:atomics still compiles
# the Odin side's wasm_memory_atomic_wait32. The module builds, stages, gzips
# and deploys clean, then traps in the browser on the first physics step with
# "Atomics.wait cannot be called in this context" - on the main thread, where
# the spec forbids blocking.
#
# That shipped to production once. The pinned master checkout reports the exact
# revision and so passed assert_toolchain, while the checkout that actually has
# the threading work is built locally and reports no revision at all, which only
# earns a warning. The guard therefore preferred the wrong toolchain.
#
# So check for the artifact itself rather than any version string.
assert_box3d_threads() {
	local root object
	if ! root="$(odin root 2>/dev/null)"; then
		echo "error: could not resolve the Odin root via 'odin root'" >&2
		exit 1
	fi
	object="${root%/}/vendor/box3d/lib/box3d_wasm_threads.o"
	if [ ! -s "$object" ]; then
		echo "error: threaded build requested but the box3d threaded object is missing" >&2
		echo "       expected: $object" >&2
		echo "       This Odin has the single-threaded box3d vendor. Build with the" >&2
		echo "       checkout carrying the Box3D wasm threading work, e.g." >&2
		echo "       PATH=\"/path/to/odin-box3d-workers:\$PATH\" INGOT_WEB_THREADS=1 bash build_web.sh ..." >&2
		exit 1
	fi
	# The object is tracked with Git LFS. An un-pulled pointer is a ~130 byte
	# text file that -s accepts and wasm-ld rejects far later, so name it here.
	if head -c 40 "$object" | grep -q '^version https://git-lfs.github.com/spec/v1'; then
		echo "error: $object is an un-pulled Git LFS pointer" >&2
		echo "       run: git -C \"$root\" lfs pull" >&2
		exit 1
	fi
	if ! grep -q 'BOX3D_WASM_THREADS' "${root%/}/vendor/box3d/box3d.odin"; then
		echo "error: $object exists but vendor/box3d/box3d.odin cannot select it" >&2
		echo "       the bindings have no BOX3D_WASM_THREADS config, so LIB_PATH" >&2
		echo "       resolves to the single-threaded lib/box3d_wasm.o regardless" >&2
		exit 1
	fi
	echo "Box3D threaded object: $object"
}

echo "Building wasm..."
# --export-table is REQUIRED by vendor:wgpu on JS so the browser glue can invoke
# Odin callbacks (adapter/device requests) through the function table.
# The demo drives the real ingot:gfx engine, so the ingot collection is needed.
#
# An optional argument selects a different entry point, e.g.:
#   bash build_web.sh examples/breakout    # a package directory
#   bash build_web.sh web/demo.odin        # a single file (default)
SRC="${1:-$WEB/demo.odin}"
WEB_THREADS="${INGOT_WEB_THREADS:-0}"
FILE_FLAG="-file"
if [ -d "$SRC" ]; then FILE_FLAG=""; fi
TARGET_FLAGS=""
LINKER_FLAGS="--export-table"
if [ "$WEB_THREADS" = "1" ]; then
	assert_box3d_threads
	TARGET_FLAGS="-target-features:atomics"
	TARGET_FLAGS="$TARGET_FLAGS -define:BOX3D_WASM_THREADS=true"
	TARGET_FLAGS="$TARGET_FLAGS -define:INGOT_BOX3D_WORKERS=true"
	LINKER_FLAGS="$LINKER_FLAGS --shared-memory --import-memory --export=__stack_pointer"
	LINKER_FLAGS="$LINKER_FLAGS --initial-memory=67108864 --max-memory=268435456"
	LINKER_FLAGS="$LINKER_FLAGS -z stack-size=8388608"
fi
if [ -n "${INGOT_BOX3D_BENCHMARK_BODY_COUNT:-}" ]; then
	TARGET_FLAGS="$TARGET_FLAGS -define:INGOT_BOX3D_BENCHMARK_BODY_COUNT=$INGOT_BOX3D_BENCHMARK_BODY_COUNT"
fi
if [ -n "${INGOT_BOX3D_BENCHMARK_WARMUP_STEPS:-}" ]; then
	TARGET_FLAGS="$TARGET_FLAGS -define:INGOT_BOX3D_BENCHMARK_WARMUP_STEPS=$INGOT_BOX3D_BENCHMARK_WARMUP_STEPS"
fi
if [ -n "${INGOT_BOX3D_BENCHMARK_MEASURED_BATCH_COUNT:-}" ]; then
	TARGET_FLAGS="$TARGET_FLAGS -define:INGOT_BOX3D_BENCHMARK_MEASURED_BATCH_COUNT=$INGOT_BOX3D_BENCHMARK_MEASURED_BATCH_COUNT"
fi
if [ -n "${INGOT_BOX3D_BENCHMARK_STEPS_PER_BATCH:-}" ]; then
	TARGET_FLAGS="$TARGET_FLAGS -define:INGOT_BOX3D_BENCHMARK_STEPS_PER_BATCH=$INGOT_BOX3D_BENCHMARK_STEPS_PER_BATCH"
fi
if [ -n "${INGOT_BOX3D_BENCHMARK_PHYSICS_SUBSTEPS:-}" ]; then
	TARGET_FLAGS="$TARGET_FLAGS -define:INGOT_BOX3D_BENCHMARK_PHYSICS_SUBSTEPS=$INGOT_BOX3D_BENCHMARK_PHYSICS_SUBSTEPS"
fi
# No optimisation flag is set here, and that is a measured decision rather than
# an oversight. Most of the binary is fixed-capacity data, so web uses the
# measured phone-safe batch floor below. The GPU stream defaults are also
# capped at 4 MiB per slot: adapter maxBufferSize is an allocation ceiling, not
# a memory budget, and using its desktop-sized allowance retained up to 96 MiB
# of GPU buffers plus matching WASM shadows on mobile.
#
# Measured on examples/gallery, so nobody has to re-derive this:
#
#   default                    12,280,961 bytes
#   -o:size                    12,181,913 bytes   0.8% smaller
#   -o:speed                   12,149,770 bytes   1.1% smaller
#   -o:size -disable-assert    11,977,472 bytes   2.5% smaller
#
# -o:size was tried and reverted: on examples/hello it took the build from
# 424 ms to 1800 ms (4.2x) for 1.3% less output, and check-web.sh compiles five
# wasm targets, so it cost about seven seconds on every web gate run.
#
# -disable-assert is deliberately NOT used either: it would buy another 1.7%
# while removing every Tiger Style assertion from the shipped demo, which is
# exactly the diagnostic signal we want when a browser kills the tab.
# The gallery phone peak is 26,964 vertices / 31,374 indices; these capacities
# retain more than 4x headroom while halving the resident WASM batch arrays.
# shellcheck disable=SC2086
odin build "$SRC" $FILE_FLAG \
	-target:js_wasm32 \
	$TARGET_FLAGS \
	-collection:ingot="$ROOT" \
	-out:"$WEB/ingot_web.wasm" \
	-define:INGOT_GPU_GEOMETRY_BYTES=4194304 \
	-define:INGOT_GPU_UNIFORM_BYTES=4194304 \
	-define:INGOT_BATCH_MAX_VERTICES=131072 \
	-define:INGOT_BATCH_MAX_INDICES=196608 \
	-extra-linker-flags:"$LINKER_FLAGS"

echo "Staging JS runtimes..."
"$ROOT/scripts/stage-web-runtime.sh" "$WEB"

echo "Done. Serve web/ and open index.html in a WebGPU browser:"
echo "  (cd '$WEB' && python3 -m http.server 8000) then open http://localhost:8000"
