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
# shellcheck disable=SC2086
odin build "$SRC" $FILE_FLAG \
	-target:js_wasm32 \
	-collection:ingot="$ROOT" \
	-out:"$WEB/ingot_web.wasm" \
	-extra-linker-flags:"--export-table"

echo "Staging JS runtimes..."
"$ROOT/scripts/stage-web-runtime.sh" "$WEB"

echo "Done. Serve web/ and open index.html in a WebGPU browser:"
echo "  (cd '$WEB' && python3 -m http.server 8000) then open http://localhost:8000"
