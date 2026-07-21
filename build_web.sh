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

# Locate the Odin vendor JS runtimes.
ODIN_BIN="$(command -v odin)"
ODIN_ROOT="$(dirname "$(readlink "$ODIN_BIN" 2>/dev/null || echo "$ODIN_BIN")")"
# Homebrew symlink resolves into libexec; fall back to `odin root` if present.
if [ ! -f "$ODIN_ROOT/core/sys/wasm/js/odin.js" ]; then
	ODIN_ROOT="$(odin root 2>/dev/null || echo "$ODIN_ROOT")"
fi

echo "Building wasm..."
# --export-table is REQUIRED by vendor:wgpu on JS so the browser glue can invoke
# Odin callbacks (adapter/device requests) through the function table.
# The demo drives the real ingot:gfx engine, so the ingot collection is needed.
odin build "$WEB/demo.odin" -file \
	-target:js_wasm32 \
	-collection:ingot="$ROOT" \
	-out:"$WEB/ingot_web.wasm" \
	-extra-linker-flags:"--export-table"

echo "Staging JS runtimes..."
cp "$ODIN_ROOT/core/sys/wasm/js/odin.js" "$WEB/odin.js"
cp "$ODIN_ROOT/vendor/wgpu/wgpu.js"       "$WEB/wgpu.js"
# ingot_web.js / ingot_input.js are committed host glue (not staged from Odin).

echo "Done. Serve web/ and open index.html in a WebGPU browser:"
echo "  (cd '$WEB' && python3 -m http.server 8000) then open http://localhost:8000"
