#!/usr/bin/env bash
# check-web.sh — Web-target gate: compiles the example apps for js_wasm32
# (catches missing #+build !js tags and web-platform-seam breakage that
# native checks can't see) and runs the web lifecycle JS tests under
# `node --test` against the hand-rolled DOM stub (web/test/dom_stub.mjs; no
# npm dependencies).
#
# Fast and headless — safe for CI. Real-browser assistive-tech behavior
# remains a manual pass (VoiceOver+Safari / ChromeVox).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "== wasm compile: examples/hello =="
bash "$ROOT/build_web.sh" examples/hello >/dev/null

echo "== wasm compile: examples/gallery =="
bash "$ROOT/build_web.sh" examples/gallery >/dev/null

echo "== wasm compile: examples/breakout =="
bash "$ROOT/build_web.sh" examples/breakout >/dev/null

echo "== wasm compile: examples/raylib_migration_fixture =="
bash "$ROOT/build_web.sh" examples/raylib_migration_fixture >/dev/null

echo "== wasm compile: default web demo =="
bash "$ROOT/build_web.sh" >/dev/null

echo "== web lifecycle and semantic tests =="
node --test "$ROOT"/web/test/*.test.mjs

echo "check-web: PASS"
