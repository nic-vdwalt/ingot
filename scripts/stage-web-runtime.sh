#!/usr/bin/env bash
set -euo pipefail
if [ "$#" -ne 1 ]; then
	echo "usage: $0 DESTINATION" >&2
	exit 2
fi
DEST="$1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ODIN_BIN="$(command -v odin)"
ODIN_ROOT="$(dirname "$(readlink "$ODIN_BIN" 2>/dev/null || echo "$ODIN_BIN")")"
if [ ! -f "$ODIN_ROOT/core/sys/wasm/js/odin.js" ]; then
	ODIN_ROOT="$(odin root 2>/dev/null || echo "$ODIN_ROOT")"
fi
mkdir -p "$DEST"
cp "$ODIN_ROOT/core/sys/wasm/js/odin.js" "$DEST/odin.js"
cp "$ODIN_ROOT/vendor/wgpu/wgpu.js" "$DEST/wgpu.js"
python3 - "$DEST/wgpu.js" <<'PY'
import sys
path = sys.argv[1]
source = open(path).read()
needle = "this.mem.storeI32(texturePtr + 4, textureIdx);"
status = "this.mem.storeI32(texturePtr + 8, 1);"
if status not in source:
    if source.count(needle) != 1:
        raise SystemExit("unexpected Odin WebGPU surface texture implementation")
    source = source.replace(needle, needle + "\n\t\t\t\t" + status, 1)
    open(path, "w").write(source)
if open(path).read().count(status) != 1:
    raise SystemExit("invalid SurfaceTexture.status compatibility transform")
PY
cp "$ROOT/web/ingot_web.js" "$DEST/ingot_web.js"
cp "$ROOT/web/ingot_input.js" "$DEST/ingot_input.js"
cp "$ROOT/web/ingot_app.js" "$DEST/ingot_app.js"
