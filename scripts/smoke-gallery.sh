#!/usr/bin/env bash
# smoke-gallery.sh — Automated crash smoke test for the widget gallery.
#
# Builds examples/gallery with -define:INGOT_SMOKE=true, which makes the
# gallery drive itself: it steps through every UI-scale preset, all themes
# (dark/light/high-contrast/reduced-motion), and every section — through the
# same handlers real input reaches — then exits 0. A crash or GPU validation
# abort anywhere in that sequence yields a nonzero exit.
#
# Needs a display (opens a real window). Not part of scripts/test.sh; run
# explicitly or from a CI job with a display server:
#   scripts/smoke-gallery.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/ingot_gallery_smoke"

echo "Building gallery (smoke mode)..."
odin build "$ROOT/examples/gallery" \
	-collection:ingot="$ROOT" \
	-define:INGOT_SMOKE=true \
	-debug \
	-out:"$OUT"

echo "Running smoke sequence..."
if "$OUT"; then
	echo "smoke-gallery: PASS"
else
	code=$?
	echo "smoke-gallery: FAIL (exit $code)" >&2
	exit "$code"
fi
