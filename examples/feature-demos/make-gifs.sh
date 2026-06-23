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
# netscape composites a big 34-frame GIF twice before it starts animating; this
# is the upper bound we let it run while waiting for its capture markers (it
# stops early once it has two — the actual GIF is just one loop, see LOOP_DEMOS).
declare -A DUR_OVERRIDE=([netscape]=30)

# Demos captured as a single seamless loop: the demo emits a capture marker once
# per animation loop (TTYGIF_MARK), and the recorder films exactly the span
# between two consecutive markers — one true loop — so the GIF tiles with no
# visible seam and looks like it runs forever.
LOOP_DEMOS=(netscape)

# Per-demo window-size overrides (none — every GIF is the same COLS x ROWS).
declare -A COLS_OVERRIDE=()
declare -A ROWS_OVERRIDE=()

# Static demos: saved as a single still .png instead of an animated .gif.
STILL=(png_image)

# Media::Glyph render variants — one still PNG per mode, all of the same image.
GLYPH_MODES=(block ascii half quadrant sextant octant braille)

# All demos, in display order. Pass names as args to build a subset.
ALL=(concurrent_rendering truecolor unicode mouse widgets layout image \
     styling terminfo events diff_rendering \
     matrix dashboard clock \
     png_image netscape cracktro glyph_modes overlay)

DEMOS=("$@")
if [ "${#DEMOS[@]}" -eq 0 ]; then
  DEMOS=("${ALL[@]}")
fi

echo "Window: ${COLS}x${ROWS}  duration=${DURATION}s  fps=${FPS}  font=${FONT_SIZE}  scale=${SCALE}"
echo

for demo in "${DEMOS[@]}"; do
  # Special case: Media::Glyph render variants -> one still PNG per mode.
  if [ "$demo" = "glyph_modes" ]; then
    echo ">> glyph_modes (one still PNG per drawing mode)"
    echo "   building ..."
    crystal build "$HERE/glyph_mode.cr" -o "$BUILD/glyph_mode" 2>&1 | sed 's/^/   /' || {
      echo "   build FAILED, skipping"; continue; }
    for m in "${GLYPH_MODES[@]}"; do
      GLYPH_MODE="$m" python3 "$RECORDER" \
        --out "$OUT/matterhorn-$m.png" \
        --cols "$COLS" --rows "$ROWS" --duration 2 \
        --font-size "$FONT_SIZE" --scale "$SCALE" \
        -- "$BUILD/glyph_mode"
    done
    echo
    continue
  fi

  # Special case: Media::Overlay (w3mimgdisplay) — real X11 pixel overlay, so it
  # can't go through the pseudo-terminal recorder. We run it in a real xterm on
  # $DISPLAY and screenshot that window with ffmpeg. The demo self-terminates
  # (OVERLAY_SECONDS), and we only ever kill the one PID we started — never a
  # broad pkill, which would take down other terminals on the display.
  if [ "$demo" = "overlay" ]; then
    echo ">> overlay (Media::Overlay / w3mimgdisplay true-color, needs X + xterm)"
    if [ -z "${DISPLAY:-}" ] || ! command -v xterm >/dev/null \
       || ! command -v xwininfo >/dev/null || ! command -v ffmpeg >/dev/null \
       || [ ! -x /usr/lib/w3m/w3mimgdisplay ]; then
      echo "   skipped: needs DISPLAY, xterm, xwininfo, ffmpeg and w3mimgdisplay"; echo; continue
    fi
    crystal build "$HERE/overlay_image.cr" -o "$BUILD/overlay_image" 2>&1 | sed 's/^/   /' || {
      echo "   build FAILED, skipping"; continue; }
    PATH="$PATH:/usr/lib/w3m" OVERLAY_SECONDS=12 \
      xterm -fa 'DejaVu Sans Mono' -fs "$FONT_SIZE" -geometry "${COLS}x${ROWS}+40+40" \
      -e "$BUILD/overlay_image" &
    xpid=$!
    sleep 4.5
    info=$(xwininfo -name Overlay 2>/dev/null || true)
    gx=$(awk '/Absolute upper-left X/{print $4}' <<<"$info")
    gy=$(awk '/Absolute upper-left Y/{print $4}' <<<"$info")
    gw=$(awk '/Width:/{print $2}' <<<"$info")
    gh=$(awk '/Height:/{print $2}' <<<"$info")
    if [ -n "$gw" ]; then
      ffmpeg -hide_banner -loglevel error -f x11grab -video_size "${gw}x${gh}" \
        -i "${DISPLAY}+${gx},${gy}" -frames:v 1 -y /tmp/_overlay_grab.png
      python3 - "$OUT/png_image.png" /tmp/_overlay_grab.png "$OUT/matterhorn-overlay.png" <<'PY'
import sys
from PIL import Image
ref, src, dst = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    w, h = Image.open(ref).size            # match the other outputs' size
except Exception:
    w, h = 880, 330
Image.open(src).convert("RGB").resize((w, h), Image.LANCZOS).save(dst)
print("   wrote", dst, (w, h))
PY
    else
      echo "   could not locate the window (w3m overlay may be unsupported here)"
    fi
    kill "$xpid" 2>/dev/null || true   # only this PID; demo self-exits anyway
    echo
    continue
  fi

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

  # Static demos are saved as a single still PNG (a .png output switches the
  # recorder into still mode) so they don't flicker as a short looping GIF.
  ext="gif"
  case " ${STILL[*]} " in *" $demo "*) ext="png" ;; esac

  # Loop demos are captured marker-to-marker (one seamless animation loop);
  # everything else uses a fixed duration.
  is_loop=0
  case " ${LOOP_DEMOS[*]} " in *" $demo "*) is_loop=1 ;; esac
  if [ "$is_loop" = 1 ]; then
    TTYGIF_MARK=1 python3 "$RECORDER" \
      --out "$OUT/$demo.$ext" \
      --cols "$cols" --rows "$rows" \
      --duration "$dur" --fps "$FPS" \
      --font-size "$FONT_SIZE" --scale "$SCALE" \
      --mark \
      -- "$BUILD/$demo"
  else
    python3 "$RECORDER" \
      --out "$OUT/$demo.$ext" \
      --cols "$cols" --rows "$rows" \
      --duration "$dur" --fps "$FPS" \
      --font-size "$FONT_SIZE" --scale "$SCALE" \
      -- "$BUILD/$demo"
  fi
  echo
done

echo "Done. Output in: $OUT"
ls -la "$OUT"/*.gif "$OUT"/*.png 2>/dev/null | sed 's/^/  /' || true
