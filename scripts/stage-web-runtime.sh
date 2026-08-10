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
# accepts shared views, which is why `node --test` never sees this;
# scripts/check_shared_views.py is the gate.
# The replacements below are byte-identical to odin-lang/Odin#7272, so once that
# lands every transform no-ops and this whole block can be deleted.
python3 - "$DEST/odin.js" <<'PY'
import sys
path = sys.argv[1]
source = open(path).read()

CTOR_OLD = (
	"\t\tthis.listenerMap = new Map();\n"
	"\n"
	"\t\t// Size (in bytes) of the integer type"
)
CTOR_NEW = (
	"\t\tthis.listenerMap = new Map();\n"
	"\n"
	"\t\t// Whether `memory.buffer` is a SharedArrayBuffer. Resolved once in\n"
	"\t\t// setMemory; Web APIs that reject shared views are checked against it.\n"
	"\t\tthis.isShared = false;\n"
	"\n"
	"\t\t// Size (in bytes) of the integer type"
)

SETMEM_OLD = (
	"\tsetMemory(memory) {\n"
	"\t\tthis.memory = memory;\n"
	"\t}"
)
SETMEM_NEW = (
	"\tsetMemory(memory) {\n"
	"\t\tthis.memory = memory;\n"
	"\t\t// Not `instanceof`, so a memory transferred in from another realm (an\n"
	"\t\t// iframe, or a worker with its own intrinsics) is still detected.\n"
	"\t\tthis.isShared = typeof SharedArrayBuffer !== \"undefined\" && memory != null &&\n"
	"\t\t\tObject.prototype.toString.call(memory.buffer) === \"[object SharedArrayBuffer]\";\n"
	"\t}"
)

DECODE_OLD = (
	"\tloadString(ptr, len) {\n"
	"\t\tconst bytes = this.loadBytes(ptr, Number(len));\n"
	"\t\treturn new TextDecoder().decode(bytes);\n"
	"\t}"
)
DECODE_NEW = (
	"\t// Copy out of a shared memory so the result can be passed to Web APIs that\n"
	"\t// reject SharedArrayBuffer-backed views. The Encoding spec allows shared\n"
	"\t// input (AllowSharedBufferSource) but neither Blink nor Gecko implement it,\n"
	"\t// so with `--import-memory` and a `shared: true` memory the uncopied view\n"
	"\t// throws a TypeError. Node accepts shared views, so this never reproduces\n"
	"\t// outside a browser.\n"
	"\tloadBytesUnshared(ptr, len) {\n"
	"\t\tconst bytes = this.loadBytes(ptr, len);\n"
	"\t\tif (this.isShared) {\n"
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
	"\t\t\t\t// getRandomValues fills in place and rejects a shared view, so a\n"
	"\t\t\t\t// shared memory needs an unshared staging buffer written back.\n"
	"\t\t\t\t// Copying the view alone would discard the entropy.\n"
	"\t\t\t\tif (wasmMemoryInterface.isShared) {\n"
	"\t\t\t\t\tconst tmp = new Uint8Array(len)\n"
	"\t\t\t\t\tcrypto.getRandomValues(tmp)\n"
	"\t\t\t\t\tview.set(tmp)\n"
	"\t\t\t\t\treturn\n"
	"\t\t\t\t}\n"
	"\t\t\t\tcrypto.getRandomValues(view)\n"
	"\t\t\t},"
)

# (label, already-applied sentinel, expected sentinel count, old text, new text).
# Each transform is independent and idempotent, so a partially upstreamed fix
# still gets the remaining pieces instead of being skipped wholesale.
TRANSFORMS = (
    ("constructor", "this.isShared = false;",                   1, CTOR_OLD,   CTOR_NEW),
    ("setMemory",   "this.isShared = typeof SharedArrayBuffer", 1, SETMEM_OLD, SETMEM_NEW),
    ("loadString",  "loadBytesUnshared",                        2, DECODE_OLD, DECODE_NEW),
    ("rand_bytes",  "wasmMemoryInterface.isShared",             1, RAND_OLD,   RAND_NEW),
)

changed = False
for label, sentinel, _count, old, new in TRANSFORMS:
    if sentinel in source:
        continue
    if source.count(old) != 1:
        raise SystemExit("unexpected Odin %s implementation" % label)
    source = source.replace(old, new, 1)
    changed = True
if changed:
    open(path, "w").write(source)

result = open(path).read()
for label, sentinel, count, _old, _new in TRANSFORMS:
    if result.count(sentinel) != count:
        raise SystemExit("invalid SharedArrayBuffer compatibility transform: %s" % label)
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
