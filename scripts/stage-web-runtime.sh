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
# Threaded builds import a `shared: true` memory. Blink and Gecko both reject
# SharedArrayBuffer-backed views in TextDecoder.decode and crypto.getRandomValues,
# so the stock runtime throws on the first string read or rand_bytes call. Node
# accepts shared views, which is why `node --test` never sees this. Delete this
# block once the upstream fix lands (odin-lang/Odin, wasm js shared memory).
python3 - "$DEST/odin.js" <<'PY'
import sys
path = sys.argv[1]
source = open(path).read()

GUARD = "bytes.buffer instanceof SharedArrayBuffer"

DECODE_OLD = (
	"\tloadString(ptr, len) {\n"
	"\t\tconst bytes = this.loadBytes(ptr, Number(len));\n"
	"\t\treturn new TextDecoder().decode(bytes);\n"
	"\t}"
)
DECODE_NEW = (
	"\tloadBytesUnshared(ptr, len) {\n"
	"\t\tconst bytes = this.loadBytes(ptr, len);\n"
	"\t\tif (typeof SharedArrayBuffer !== \"undefined\" && bytes.buffer instanceof SharedArrayBuffer) {\n"
	"\t\t\treturn bytes.slice();\n"
	"\t\t}\n"
	"\t\treturn bytes;\n"
	"\t}\n"
	"\n"
	"\tloadString(ptr, len) {\n"
	"\t\treturn new TextDecoder().decode(this.loadBytesUnshared(ptr, Number(len)));\n"
	"\t}"
)

RAND_OLD = (
	"\t\t\trand_bytes: (ptr, len) => {\n"
	"\t\t\t\tconst view = new Uint8Array(wasmMemoryInterface.memory.buffer, ptr, len)\n"
	"\t\t\t\tcrypto.getRandomValues(view)\n"
	"\t\t\t},"
)
RAND_NEW = (
	"\t\t\trand_bytes: (ptr, len) => {\n"
	"\t\t\t\tconst view = new Uint8Array(wasmMemoryInterface.memory.buffer, ptr, len)\n"
	"\t\t\t\tif (typeof SharedArrayBuffer !== \"undefined\" && view.buffer instanceof SharedArrayBuffer) {\n"
	"\t\t\t\t\tconst tmp = new Uint8Array(len)\n"
	"\t\t\t\t\tcrypto.getRandomValues(tmp)\n"
	"\t\t\t\t\tview.set(tmp)\n"
	"\t\t\t\t\treturn\n"
	"\t\t\t\t}\n"
	"\t\t\t\tcrypto.getRandomValues(view)\n"
	"\t\t\t},"
)

if GUARD not in source:
    if source.count(DECODE_OLD) != 1:
        raise SystemExit("unexpected Odin loadString implementation")
    if source.count(RAND_OLD) != 1:
        raise SystemExit("unexpected Odin rand_bytes implementation")
    source = source.replace(DECODE_OLD, DECODE_NEW, 1)
    source = source.replace(RAND_OLD, RAND_NEW, 1)
    open(path, "w").write(source)

result = open(path).read()
if result.count(GUARD) != 1:
    raise SystemExit("invalid SharedArrayBuffer compatibility transform: loadString")
if result.count("view.buffer instanceof SharedArrayBuffer") != 1:
    raise SystemExit("invalid SharedArrayBuffer compatibility transform: rand_bytes")
PY
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
if [ "$ROOT/web" != "$(cd "$DEST" && pwd)" ]; then
	cp "$ROOT/web/ingot_web.js" "$DEST/ingot_web.js"
	cp "$ROOT/web/ingot_input.js" "$DEST/ingot_input.js"
	cp "$ROOT/web/ingot_app.js" "$DEST/ingot_app.js"
	cp "$ROOT/web/ingot_crash.js" "$DEST/ingot_crash.js"
	# Box3D worker pool. box3d_worker.js is loaded by new Worker() from
	# box3d_workers.js relative to the DOCUMENT url, so it must sit next to
	# index.html even though no <script> tag ever references it.
	cp "$ROOT/web/box3d_workers.js" "$DEST/box3d_workers.js"
	cp "$ROOT/web/box3d_worker.js" "$DEST/box3d_worker.js"
fi
