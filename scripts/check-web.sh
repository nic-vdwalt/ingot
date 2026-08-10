#!/usr/bin/env bash
# check-web.sh - Web-target gate: compiles the example apps for js_wasm32
# (catches missing #+build !js tags and web-platform-seam breakage that
# native checks can't see) and runs the web lifecycle JS tests under
# `node --test` against the hand-rolled DOM stub (web/test/dom_stub.mjs; no
# npm dependencies).
#
# Fast and headless - safe for CI. Real-browser assistive-tech behavior
# remains a manual pass (VoiceOver+Safari / ChromeVox).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# The vendored Box3D objects are Git LFS-tracked. On a checkout made without
# git-lfs they are 130-byte text pointers, and the only symptom is an opaque
# `wasm-ld: error: unknown file type` several minutes into the gate. Name the
# real problem up front instead.
check_box3d_artifacts() {
	local odin_root
	odin_root="$(odin root 2>/dev/null)" || return 0
	[ -n "$odin_root" ] || return 0
	local lib_dir="${odin_root%/}/vendor/box3d/lib"
	[ -d "$lib_dir" ] || return 0
	local artifact
	for artifact in "$lib_dir/box3d_wasm.o" "$lib_dir/box3d_wasm_threads.o" \
		"$lib_dir/darwin/libbox3d.a"; do
		[ -f "$artifact" ] || continue
		if head -c 40 "$artifact" | grep -q "git-lfs.github.com/spec"; then
			echo "check-web: $artifact is a Git LFS pointer, not a real object." >&2
			echo "check-web: install git-lfs and run 'git lfs pull' in $odin_root," >&2
			echo "check-web: or rebuild with 'bash vendor/box3d/src/build.sh'." >&2
			exit 1
		fi
	done
}
check_box3d_artifacts

echo "== wasm compile: examples/hello =="
bash "$ROOT/build_web.sh" examples/hello >/dev/null

echo "== wasm compile: examples/gallery =="
bash "$ROOT/build_web.sh" examples/gallery >/dev/null

echo "== wasm compile: examples/breakout =="
bash "$ROOT/build_web.sh" examples/breakout >/dev/null

echo "== wasm compile: examples/procgen_world =="
bash "$ROOT/build_web.sh" examples/procgen_world >/dev/null

echo "== wasm compile: examples/box3d_stack =="
bash "$ROOT/build_web.sh" examples/box3d_stack >/dev/null

if [ "${INGOT_CHECK_WEB_THREADS:-0}" = "1" ]; then
	echo "== wasm compile: threaded examples/box3d_stack =="
	INGOT_WEB_THREADS=1 bash "$ROOT/build_web.sh" examples/box3d_stack >/dev/null
	python3 "$ROOT/scripts/check_wasm_threads.py" "$ROOT/web/ingot_web.wasm"
	echo "== wasm compile: threaded examples/box3d_benchmark =="
	INGOT_WEB_THREADS=1 bash "$ROOT/build_web.sh" examples/box3d_benchmark >/dev/null
	python3 "$ROOT/scripts/check_wasm_threads.py" "$ROOT/web/ingot_web.wasm" \
		--required-export ingot_box3d_benchmark_batch
fi

echo "== wasm compile: examples/box3d_advanced =="
bash "$ROOT/build_web.sh" examples/box3d_advanced >/dev/null

echo "== wasm compile: examples/box3d_water =="
bash "$ROOT/build_web.sh" examples/box3d_water >/dev/null

echo "== wasm compile: examples/raylib_migration_fixture =="
bash "$ROOT/build_web.sh" examples/raylib_migration_fixture >/dev/null

echo "== wasm compile: default web demo =="
bash "$ROOT/build_web.sh" >/dev/null

# examples/wss_fixture is a native-only CLI (argv/exit codes via core:os), so
# it can't be built for the web; type-check net for js instead so the web
# WebSocket backend (ws_web.odin) can't rot unnoticed.
echo "== wasm check: net =="
(cd "$ROOT" && odin check net -collection:ingot=. -target:js_wasm32 -no-entry-point)

# The last build left its module in web/; check it for the zero-segment bloat
# that a static initialiser on a large global reintroduces. See
# check_wasm_bloat.py - this cost 11 MB of every demo download until it was
# found, and nothing else in the tree would notice it coming back.
echo "== wasm data segment bloat =="
python3 "$ROOT/scripts/check_wasm_bloat.py" "$ROOT/web/ingot_web.wasm" --report

echo "== web lifecycle and semantic tests =="
node --test "$ROOT"/web/test/*.test.mjs

echo "check-web: PASS"
