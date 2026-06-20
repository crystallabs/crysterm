#!/usr/bin/env bash
#
# make-gifs.sh — compile each feature demo, run it in a fixed-size pseudo-
# terminal, and save an animated GIF of how it looks. Re-run any time to refresh
# the GIFs (e.g. after changing a demo or the framework).
#
# Output GIFs land in   screenshots/features/<demo>.gif
#
# Everything is configurable via environment variables:
#
#   COLS=80 ROWS=15 ./make-gifs.sh                 # window size (default 80x15)
#   DURATION=3 FPS=12 ./make-gifs.sh               # capture seconds / frame rate
#   FONT_SIZE=18 SCALE=1 ./make-gifs.sh            # rendering size
#   ./make-gifs.sh truecolor unicode               # only these demos
#
# Requirements: crystal (to build the demos) and python3 with Pillow (used by
# the bundled ttygif.py recorder — no external binaries or network needed).

set -euo pipefail

# --- locations -------------------------------------------------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BUILD="$ROOT/.tooling/build"
OUT="$ROOT/screenshots/features"
RECORDER="$HERE/ttygif.py"

mkdir -p "$BUILD" "$OUT"

# --- configuration (override via env) --------------------------------------
COLS="${COLS:-80}"
ROWS="${ROWS:-15}"
DURATION="${DURATION:-5}"
FPS="${FPS:-12}"
FONT_SIZE="${FONT_SIZE:-18}"
SCALE="${SCALE:-1}"

# Per-demo capture duration overrides (some look better a touch longer/shorter).
declare -A DUR_OVERRIDE=()

# Per-demo window-size overrides (none — every GIF is the same COLS x ROWS).
declare -A COLS_OVERRIDE=()
declare -A ROWS_OVERRIDE=()

# All demos, in display order. Pass names as args to build a subset.
ALL=(concurrent_rendering truecolor unicode mouse widgets layout image \
     styling terminfo events diff_rendering \
     matrix dashboard clock \
     png_image ascii_image cracktro)

DEMOS=("$@")
if [ "${#DEMOS[@]}" -eq 0 ]; then
  DEMOS=("${ALL[@]}")
fi

echo "Window: ${COLS}x${ROWS}  duration=${DURATION}s  fps=${FPS}  font=${FONT_SIZE}  scale=${SCALE}"
echo

for demo in "${DEMOS[@]}"; do
  src="$HERE/$demo.cr"
  if [ ! -f "$src" ]; then
    echo "!! no such demo: $demo  (skipping)"
    continue
  fi
  echo ">> $demo"
  echo "   building ..."
  crystal build "$src" -o "$BUILD/$demo" 2>&1 | sed 's/^/   /' || {
    echo "   build FAILED, skipping"; continue; }

  dur="${DUR_OVERRIDE[$demo]:-$DURATION}"
  cols="${COLS_OVERRIDE[$demo]:-$COLS}"
  rows="${ROWS_OVERRIDE[$demo]:-$ROWS}"
  python3 "$RECORDER" \
    --out "$OUT/$demo.gif" \
    --cols "$cols" --rows "$rows" \
    --duration "$dur" --fps "$FPS" \
    --font-size "$FONT_SIZE" --scale "$SCALE" \
    -- "$BUILD/$demo"
  echo
done

echo "Done. GIFs in: $OUT"
ls -la "$OUT"/*.gif 2>/dev/null | sed 's/^/  /' || true
