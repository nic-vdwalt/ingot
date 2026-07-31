#!/usr/bin/env bash
# smoke-view-builder.sh - Automated crash smoke test for the view builder.
#
# Builds examples/view_builder with -define:INGOT_SMOKE=true, which makes the
# builder drive itself: it adds every View_Kind, cycles every token on the
# selection, deletes back down, and round-trips the document through the file
# format - all through the same handlers real clicks reach - then exits 0.
#
# It exists because the builder's failure mode is an abort rather than a wrong
# pixel. Any document the editor can reach must be one view_play can render, and
# the cheapest way to test that claim is to have the editor try.
#
# Needs a display (opens a real window). Not part of scripts/test.sh; run
# explicitly or from a CI job with a display server:
#   scripts/smoke-view-builder.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/ingot_view_builder_smoke"

echo "Building view builder (smoke mode)..."
odin build "$ROOT/examples/view_builder" \
	-collection:ingot="$ROOT" \
	-define:INGOT_SMOKE=true \
	-debug \
	-out:"$OUT"

echo "Running smoke sequence..."
if "$OUT"; then
	echo "smoke-view-builder: PASS"
else
	code=$?
	echo "smoke-view-builder: FAIL (exit $code)" >&2
	exit "$code"
fi
