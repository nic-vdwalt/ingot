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
# Failure paths in the vendored WebGPU glue, all of which reach phones first:
#
# - requestAdapter / requestDevice are written `.catch(err).then(ok)`. After a
#   rejection `ok` still runs with `undefined`, so Odin receives a SECOND
#   callback for a request it already freed (gfx/platform_web.odin), and
#   `device.lost` then throws a TypeError. The device error callback also
#   omitted the device slot, so the message pointer landed in it.
# - A `null` adapter (a blocklisted mobile GPU) was reported as Success.
# - getCurrentTexture throws on an unconfigured or lost context, and the
#   exception unwound straight through wasm `step`, ending the frame loop.
#   Reporting SurfaceGetCurrentTextureStatus.Lost (5, pinned by an #assert in
#   gfx/platform_web.odin) routes it through gfx's reconfigure-and-skip path.
#
# Same contract as the blocks above: every transform is idempotent, keyed on a
# sentinel, and fails loudly if the upstream text moves.
python3 - "$DEST/wgpu.js" <<'PY'
import sys
path = sys.argv[1]
source = open(path).read()

DEV_OLD = (
    "\t\t\t\t\t\tthis.callCallback(callbackInfo, [ENUMS.RequestDeviceStatus.indexOf(\"Error\"), messageAddr]);\n"
    "\t\t\t\t\t\tthis.mem.exports.wgpu_free(messageAddr);\n"
    "\t\t\t\t\t})\n"
    "\t\t\t\t\t.then((device) => {\n"
)
DEV_NEW = (
    "\t\t\t\t\t\tthis.callCallback(callbackInfo, [ENUMS.RequestDeviceStatus.indexOf(\"Error\"), 0, messageAddr]);\n"
    "\t\t\t\t\t\tthis.mem.exports.wgpu_free(messageAddr);\n"
    "\t\t\t\t\t\treturn undefined;\n"
    "\t\t\t\t\t})\n"
    "\t\t\t\t\t.then((device) => {\n"
    "\t\t\t\t\t\tif (device === undefined) return; // ingot: rejected above\n"
)
ADP_OLD = (
    "\t\t\t\t\t.then((adapter) => {\n"
    "\t\t\t\t\t\tconst adapterIdx = this.adapters.create(adapter);\n"
)
ADP_NEW = (
    "\t\t\t\t\t.then((adapter) => {\n"
    "\t\t\t\t\t\tif (adapter === undefined) return; // ingot: rejected above\n"
    "\t\t\t\t\t\tif (adapter === null) { // ingot: no adapter is Unavailable, not Success\n"
    "\t\t\t\t\t\t\tthis.callCallback(callbackInfo, [ENUMS.RequestAdapterStatus.indexOf(\"Unavailable\"), 0, this.zeroMessageArg()]);\n"
    "\t\t\t\t\t\t\treturn;\n"
    "\t\t\t\t\t\t}\n"
    "\t\t\t\t\t\tconst adapterIdx = this.adapters.create(adapter);\n"
)
TEX_OLD = "\t\t\t\tconst texture = context.getCurrentTexture();\n"
TEX_NEW = (
    "\t\t\t\tlet texture; // ingot: guarded acquire\n"
    "\t\t\t\ttry {\n"
    "\t\t\t\t\ttexture = context.getCurrentTexture();\n"
    "\t\t\t\t} catch (e) {\n"
    "\t\t\t\t\tthis.mem.storeI32(texturePtr + 4, 0);\n"
    "\t\t\t\t\tthis.mem.storeI32(texturePtr + 8, 5); // SurfaceGetCurrentTextureStatus.Lost\n"
    "\t\t\t\t\treturn;\n"
    "\t\t\t\t}\n"
)

# (label, already-applied sentinel, old text, new text).
TRANSFORMS = (
    ("requestDevice",  "if (device === undefined) return; // ingot: rejected above",  DEV_OLD, DEV_NEW),
    ("requestAdapter", "// ingot: no adapter is Unavailable, not Success",            ADP_OLD, ADP_NEW),
    ("getCurrentTexture", "let texture; // ingot: guarded acquire",                  TEX_OLD, TEX_NEW),
)

changed = False
for label, sentinel, old, new in TRANSFORMS:
    if sentinel in source:
        continue
    if source.count(old) != 1:
        raise SystemExit("unexpected Odin WebGPU %s implementation" % label)
    source = source.replace(old, new, 1)
    changed = True
if changed:
    open(path, "w").write(source)

result = open(path).read()
EXPECTED = (
    ("rejected-promise guards", "// ingot: rejected above", 2),
    ("null adapter status", "// ingot: no adapter is Unavailable, not Success", 1),
    ("guarded surface acquire", "// ingot: guarded acquire", 1),
)
for label, sentinel, count in EXPECTED:
    if result.count(sentinel) != count:
        raise SystemExit("invalid WebGPU failure-path transform: %s" % label)
PY
# Crash telemetry in the vendored WebGPU glue. An iPhone capture showed every
# in-page metric flat while the tab was still killed, so the growth is in the
# browser's GPU process. These hooks expose what the page can see of it to the
# heartbeat in ingot_web.js: live objects per manager (a missing *Release shows
# up as one type climbing) and bytes handed to writeBuffer/writeTexture. They
# count only; no allocation per call. This file is regenerated from the Odin
# vendor copy on every stage, so hand edits to web/wgpu.js do not survive.
python3 - "$DEST/wgpu.js" <<'PY'
import sys
path = sys.argv[1]
source = open(path).read()

CTOR_OLD = "\t\tthis.zeroMessageAddr = 0;\n\t}\n\n\tstruct(start) {"
CTOR_NEW = (
    "\t\tthis.zeroMessageAddr = 0;\n"
    "\n"
    "\t\tthis.uploadBytes = 0; // ingot: telemetry\n"
    "\t}\n"
    "\n"
    "\t// ingot: live object counts per manager, for crash telemetry.\n"
    "\tliveObjectCounts() {\n"
    "\t\tconst byName = {};\n"
    "\t\tlet total = 0;\n"
    "\t\tfor (const key of Object.keys(this)) {\n"
    "\t\t\tconst manager = this[key];\n"
    "\t\t\tif (!(manager instanceof WebGPUObjectManager)) continue;\n"
    "\t\t\tconst count = manager.live();\n"
    "\t\t\tbyName[manager.name] = count;\n"
    "\t\t\ttotal += count;\n"
    "\t\t}\n"
    "\t\treturn { total, byName };\n"
    "\t}\n"
    "\n"
    "\t// ingot: returns and resets the upload byte counter.\n"
    "\ttakeUploadBytes() {\n"
    "\t\tconst bytes = this.uploadBytes;\n"
    "\t\tthis.uploadBytes = 0;\n"
    "\t\treturn bytes;\n"
    "\t}\n"
    "\n"
    "\tstruct(start) {"
)
WB_OLD = "\t\t\t\tsize = this.unwrapBigInt(size);\n\t\t\t\tqueue.writeBuffer("
WB_NEW = (
    "\t\t\t\tsize = this.unwrapBigInt(size);\n"
    "\t\t\t\tthis.uploadBytes += Number(size); // ingot: upload telemetry\n"
    "\t\t\t\tqueue.writeBuffer("
)
WT_OLD = (
    "\t\t\t\tdataSize = this.unwrapBigInt(dataSize);\n"
    "\t\t\t\tconst dataLayout = this.TexelCopyBufferLayout(dataLayoutPtr);"
)
WT_NEW = (
    "\t\t\t\tdataSize = this.unwrapBigInt(dataSize);\n"
    "\t\t\t\tthis.uploadBytes += Number(dataSize); // ingot: upload telemetry\n"
    "\t\t\t\tconst dataLayout = this.TexelCopyBufferLayout(dataLayoutPtr);"
)
LIVE_OLD = "\t\tthis.objects[idx-1].references += 1;\n\t}\n"
LIVE_NEW = (
    "\t\tthis.objects[idx-1].references += 1;\n"
    "\t}\n"
    "\n"
    "\t// ingot: number of objects still held (not yet fully released).\n"
    "\tlive() {\n"
    "\t\tlet count = 0;\n"
    "\t\tfor (const _ in this.objects) count += 1;\n"
    "\t\treturn count;\n"
    "\t}\n"
)

# (label, already-applied sentinel, old text, new text).
TRANSFORMS = (
    ("interface counters", "// ingot: live object counts per manager", CTOR_OLD, CTOR_NEW),
    ("writeBuffer bytes", "this.uploadBytes += Number(size); // ingot: upload telemetry", WB_OLD, WB_NEW),
    ("writeTexture bytes", "this.uploadBytes += Number(dataSize); // ingot: upload telemetry", WT_OLD, WT_NEW),
    ("manager live count", "// ingot: number of objects still held", LIVE_OLD, LIVE_NEW),
)

changed = False
for label, sentinel, old, new in TRANSFORMS:
    if sentinel in source:
        continue
    if source.count(old) != 1:
        raise SystemExit("unexpected Odin WebGPU %s implementation" % label)
    source = source.replace(old, new, 1)
    changed = True
if changed:
    open(path, "w").write(source)

result = open(path).read()
for label, sentinel, _old, _new in TRANSFORMS:
    if result.count(sentinel) != 1:
        raise SystemExit("invalid WebGPU telemetry transform: %s" % label)
PY
# Upload staging. Upstream hands writeBuffer/writeTexture a Uint8Array view into
# the whole wasm memory ArrayBuffer. On iOS the tab is killed after tens of MB
# of such uploads while every in-page metric stays flat, so WebKit's GPU-process
# IPC is suspected of copying or retaining far more than the viewed range.
# stagedBytes copies each upload into one pooled, dedicated buffer instead; it is
# safe to reuse because both calls copy synchronously. `?ingot_upload=view` in
# ingot_web.js sets uploadMode = "view" to restore the upstream path for A/B.
# Must run after the telemetry block above, whose text it anchors on.
python3 - "$DEST/wgpu.js" <<'PY'
import sys
path = sys.argv[1]
source = open(path).read()

CTOR_OLD = "\t\tthis.uploadBytes = 0; // ingot: telemetry\n"
CTOR_NEW = (
    "\t\tthis.uploadBytes = 0; // ingot: telemetry\n"
    "\t\tthis.uploadMode = \"pooled\"; // ingot: upload staging\n"
    "\t\tthis.uploadStaging = null;\n"
)
METHOD_OLD = (
    "\ttakeUploadBytes() {\n"
    "\t\tconst bytes = this.uploadBytes;\n"
    "\t\tthis.uploadBytes = 0;\n"
    "\t\treturn bytes;\n"
    "\t}\n"
)
METHOD_NEW = METHOD_OLD + (
    "\n"
    "\t// ingot: copies an upload out of wasm memory into a pooled buffer.\n"
    "\tstagedBytes(ptr, size) {\n"
    "\t\tconst STAGING_MIN = 64 * 1024;\n"
    "\t\tconst STAGING_MAX = 16 * 1024 * 1024;\n"
    "\t\tsize = Number(size);\n"
    "\t\tconst src = this.mem.loadBytes(ptr, size);\n"
    "\t\tif (this.uploadMode === \"view\" || size === 0) return src;\n"
    "\t\tif (size > STAGING_MAX) return src.slice();\n"
    "\t\tif (this.uploadStaging === null || this.uploadStaging.byteLength < size) {\n"
    "\t\t\tlet cap = Math.max(STAGING_MIN, this.uploadStaging ? this.uploadStaging.byteLength * 2 : 0);\n"
    "\t\t\twhile (cap < size) cap *= 2;\n"
    "\t\t\tthis.uploadStaging = new Uint8Array(Math.min(cap, STAGING_MAX));\n"
    "\t\t}\n"
    "\t\tconst view = this.uploadStaging.subarray(0, size);\n"
    "\t\tview.set(src);\n"
    "\t\treturn view;\n"
    "\t}\n"
)
WB_OLD = "this.mem.loadBytes(dataPtr, size), 0, size);"
WB_NEW = "this.stagedBytes(dataPtr, size), 0, size);"
WT_OLD = "queue.writeTexture(destination, this.mem.loadBytes(dataPtr, dataSize), dataLayout, writeSize);"
WT_NEW = "queue.writeTexture(destination, this.stagedBytes(dataPtr, dataSize), dataLayout, writeSize);"

# (label, already-applied sentinel, old text, new text).
TRANSFORMS = (
    ("staging fields", "// ingot: upload staging", CTOR_OLD, CTOR_NEW),
    ("staging method", "// ingot: copies an upload out of wasm memory", METHOD_OLD, METHOD_NEW),
    ("writeBuffer staging", "this.stagedBytes(dataPtr, size), 0, size);", WB_OLD, WB_NEW),
    ("writeTexture staging", "this.stagedBytes(dataPtr, dataSize)", WT_OLD, WT_NEW),
)

changed = False
for label, sentinel, old, new in TRANSFORMS:
    if sentinel in source:
        continue
    if source.count(old) != 1:
        raise SystemExit("unexpected Odin WebGPU %s implementation" % label)
    source = source.replace(old, new, 1)
    changed = True
if changed:
    open(path, "w").write(source)

result = open(path).read()
for label, sentinel, _old, _new in TRANSFORMS:
    if result.count(sentinel) != 1:
        raise SystemExit("invalid WebGPU upload staging transform: %s" % label)
if "this.mem.loadBytes(dataPtr, size), 0, size)" in result:
    raise SystemExit("invalid WebGPU upload staging transform: writeBuffer still uses a view")
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
