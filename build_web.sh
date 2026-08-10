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
