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
FILE_FLAG="-file"
if [ -d "$SRC" ]; then FILE_FLAG=""; fi
# -o:size trims the compiled code, but note what it does NOT fix: measured on
# examples/gallery, default is 12,280,961 bytes and -o:size is 12,181,913 - a
# 0.8% saving. Adding -disable-assert reaches 11,977,472, still only 2.5%.
#
# The reason is that 96% of the binary is the DATA section (11.5 MB) and only
# 434 KB is code: the engine's fixed-capacity inline arrays
# (gfx.Renderer.verts is 9 MiB, ui.Paint_List is 4 MiB x2) are static globals
# baked into the module. No optimisation flag touches those; only changing the
# capacities would.
#
# -disable-assert is deliberately NOT used: it would buy another 1.7% while
# removing every Tiger Style assertion from the shipped demo, which is exactly
# the diagnostic signal we want when a browser kills the tab.
# shellcheck disable=SC2086
odin build "$SRC" $FILE_FLAG \
	-target:js_wasm32 \
	-collection:ingot="$ROOT" \
	-out:"$WEB/ingot_web.wasm" \
	-o:size \
	-extra-linker-flags:"--export-table"

echo "Staging JS runtimes..."
"$ROOT/scripts/stage-web-runtime.sh" "$WEB"

echo "Done. Serve web/ and open index.html in a WebGPU browser:"
echo "  (cd '$WEB' && python3 -m http.server 8000) then open http://localhost:8000"
