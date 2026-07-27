#!/usr/bin/env bash
# capture-media.sh — Reproducible README stills and demo GIF/MP4.
#
# Builds examples/gallery with -define:INGOT_CAPTURE=true, which makes the
# gallery render itself into a fixed 1600x1000 offscreen render target and write
# PNGs through gfx.SaveRenderTexturePng (see examples/gallery/capture.odin).
# Two passes run:
#
#   stills   -> docs/media/*.png   committed, optimised, byte-reproducible
#   sequence -> dist/media/*.gif   git-ignored, uploaded as a release asset
#              dist/media/*.mp4
#
# Needs a display (opens a real window). Like scripts/smoke-gallery.sh this is
# NOT part of scripts/test.sh; run it explicitly when the media needs refreshing:
#   bash scripts/capture-media.sh
#
# Requires ffmpeg and ImageMagick (`magick`) for the encode and optimise steps.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${TMPDIR:-/tmp}/ingot_gallery_capture"
STILLS_DIR="$ROOT/docs/media"
DIST_DIR="$ROOT/dist/media"
SEQ_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ingot_capture_seq.XXXXXX")"
trap 'rm -rf "$SEQ_DIR"' EXIT

# Budgets. A README that pulls megabytes of media is a bad first impression, and
# the stills live in git forever, so both are enforced rather than advisory.
MAX_STILL_BYTES=$((400 * 1024))
MAX_GIF_BYTES=$((6 * 1024 * 1024))

for tool in ffmpeg magick; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "capture-media: $tool not found on PATH" >&2
		exit 1
	fi
done

echo "== build (capture mode) =="
odin build "$ROOT/examples/gallery" \
	-collection:ingot="$ROOT" \
	-define:INGOT_CAPTURE=true \
	-out:"$BIN"

echo "== stills -> docs/media =="
mkdir -p "$STILLS_DIR"
INGOT_CAPTURE_DIR="$STILLS_DIR" "$BIN"

echo "== optimise stills =="
still_failures=0
for png in "$STILLS_DIR"/*.png; do
	# -strip drops timestamps and colour profiles, which would otherwise make
	# two identical captures differ byte-for-byte. -define png:compression-* asks
	# for the smallest deflate; the images are flat UI art, so quantising to 256
	# colours is lossless in practice and roughly halves the size.
	magick "$png" \
		-strip \
		-colors 256 \
		-define png:compression-level=9 \
		-define png:compression-filter=5 \
		-define png:compression-strategy=1 \
		"$png"
	size=$(wc -c <"$png" | tr -d ' ')
	printf '  %-34s %8s bytes\n' "$(basename "$png")" "$size"
	if [ "$size" -gt "$MAX_STILL_BYTES" ]; then
		echo "  ^ exceeds ${MAX_STILL_BYTES} byte budget" >&2
		still_failures=$((still_failures + 1))
	fi
done
if [ "$still_failures" -gt 0 ]; then
	echo "capture-media: $still_failures still(s) over budget" >&2
	exit 1
fi

echo "== sequence -> ${SEQ_DIR} =="
INGOT_CAPTURE_DIR="$SEQ_DIR" INGOT_CAPTURE_SEQUENCE=1 "$BIN"
frames=$(find "$SEQ_DIR" -name 'frame_*.png' | wc -l | tr -d ' ')
if [ "$frames" -eq 0 ]; then
	echo "capture-media: sequence pass produced no frames" >&2
	exit 1
fi
echo "  ${frames} frames"

mkdir -p "$DIST_DIR"
GIF="$DIST_DIR/ingot-gallery.gif"
MP4="$DIST_DIR/ingot-gallery.mp4"

echo "== gif =="
# Two-pass palette: a single global palette banded the theme gradients badly.
# stats_mode=diff weights the palette toward the pixels that actually change,
# which is what a mostly-static UI recording needs.
ffmpeg -y -loglevel error -framerate 60 -i "$SEQ_DIR/frame_%05d.png" \
	-vf "fps=20,scale=1280:-1:flags=lanczos,palettegen=stats_mode=diff" \
	"$SEQ_DIR/palette.png"
ffmpeg -y -loglevel error -framerate 60 -i "$SEQ_DIR/frame_%05d.png" -i "$SEQ_DIR/palette.png" \
	-lavfi "fps=20,scale=1280:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=3" \
	"$GIF"

echo "== mp4 =="
# yuv420p and an even height keep the file playable in browsers and on GitHub.
ffmpeg -y -loglevel error -framerate 60 -i "$SEQ_DIR/frame_%05d.png" \
	-vf "scale=1280:-2:flags=lanczos,format=yuv420p" \
	-c:v libx264 -preset slow -crf 20 -movflags +faststart \
	"$MP4"

gif_bytes=$(wc -c <"$GIF" | tr -d ' ')
mp4_bytes=$(wc -c <"$MP4" | tr -d ' ')
printf '  %-34s %8s bytes\n' "$(basename "$GIF")" "$gif_bytes"
printf '  %-34s %8s bytes\n' "$(basename "$MP4")" "$mp4_bytes"
if [ "$gif_bytes" -gt "$MAX_GIF_BYTES" ]; then
	echo "capture-media: GIF exceeds ${MAX_GIF_BYTES} byte budget" >&2
	exit 1
fi

echo
echo "capture-media: PASS"
echo "  committed stills: docs/media/"
echo "  release assets:   dist/media/ (git-ignored; upload with gh release upload)"
