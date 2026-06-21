#!/usr/bin/env bash
# Capture still PNGs of the terminal-graphics image demos (sixel, ReGIS,
# Tektronix) into screenshots/features/.
#
# These can't go through the ttygif.py pseudo-terminal recorder: its built-in VT
# emulator doesn't implement sixel/ReGIS/Tek (just as it can't show the w3m
# overlay). So — exactly like the OverlayImage path in make-gifs.sh — we run
# each demo in a REAL xterm on $DISPLAY and screenshot the window with ffmpeg.
#
# Requirements:
#   * DISPLAY + xterm built with sixel, --enable-regis-graphics and
#     --enable-tek4014 (modern xterm; check `xterm -ti vt340` and `xterm -t`)
#   * xwininfo, ffmpeg, python3 + Pillow
#
# Each demo self-terminates via DEMO_SECONDS so no broad pkill is ever needed.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="$ROOT/screenshots/features"
BUILD="${BUILD:-/tmp/_crysterm_gfx_build}"
mkdir -p "$BUILD" "$OUT"

COLS="${COLS:-80}"
ROWS="${ROWS:-15}"
FONT_SIZE="${FONT_SIZE:-18}"
OUT_W="${OUT_W:-880}"   # match the other matterhorn-*.png screenshots
OUT_H="${OUT_H:-330}"

if [ -z "${DISPLAY:-}" ] || ! command -v xterm >/dev/null \
   || ! command -v xwininfo >/dev/null || ! command -v ffmpeg >/dev/null; then
  echo "skipped: needs DISPLAY, xterm, xwininfo and ffmpeg"; exit 0
fi

# normalize <src.png> <dst.png>: resize to OUT_W x OUT_H to match the set.
normalize() {
  python3 - "$1" "$2" "$OUT_W" "$OUT_H" <<'PY'
import sys
from PIL import Image
src, dst, w, h = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
Image.open(src).convert("RGB").resize((w, h), Image.LANCZOS).save(dst)
print("   wrote", dst, (w, h))
PY
}

# grab_window <wm-name> <out.png>
grab_window() {
  local name="$1" dst="$2"
  local info gx gy gw gh
  info=$(xwininfo -name "$name" 2>/dev/null || true)
  gx=$(awk '/Absolute upper-left X/{print $4}' <<<"$info")
  gy=$(awk '/Absolute upper-left Y/{print $4}' <<<"$info")
  gw=$(awk '/Width:/{print $2}' <<<"$info")
  gh=$(awk '/Height:/{print $2}' <<<"$info")
  if [ -z "$gw" ]; then echo "   could not locate window '$name'"; return 1; fi
  ffmpeg -hide_banner -loglevel error -f x11grab -video_size "${gw}x${gh}" \
    -i "${DISPLAY}+${gx},${gy}" -frames:v 1 -y "$dst"
}

build() {
  echo "   building $1 ..."
  crystal build "$HERE/$1.cr" -o "$BUILD/$1" 2>&1 | sed 's/^/   /'
  return "${PIPESTATUS[0]}"
}

# ---- sixel ---------------------------------------------------------------
echo ">> sixel (SixelImage, in-band DCS raster)"
if build sixel_image; then
  # maxGraphicSize must exceed the sixel's pixel size or xterm silently drops it.
  CELL_PW=14 CELL_PH=29 DEMO_SECONDS=10 \
    xterm -title SixelImage -fa 'DejaVu Sans Mono' -fs "$FONT_SIZE" \
      -geometry "${COLS}x${ROWS}+50+50" -ti vt340 \
      -xrm 'XTerm*numColorRegisters: 256' -xrm 'XTerm*maxGraphicSize: 4000x4000' \
      -e "$BUILD/sixel_image" &
  pid=$!; sleep 4
  if grab_window SixelImage /tmp/_sixel_grab.png; then
    normalize /tmp/_sixel_grab.png "$OUT/matterhorn-sixel.png"
  fi
  kill "$pid" 2>/dev/null || true
fi
echo

# ---- regis ---------------------------------------------------------------
echo ">> regis (RegisImage, in-band ReGIS vectors)"
if build regis_image; then
  # regisScreenSize sets ReGIS' logical screen; the demo maps the image into the
  # same extent (REGIS_W/REGIS_H) so it fills the window.
  REGIS_W=1100 REGIS_H=400 DEMO_SECONDS=12 \
    xterm -title RegisImage -fa 'DejaVu Sans Mono' -fs "$FONT_SIZE" \
      -geometry "${COLS}x${ROWS}+50+50" -ti vt340 \
      -xrm 'XTerm*numColorRegisters: 256' -xrm 'XTerm*regisScreenSize: 1100x400' \
      -e "$BUILD/regis_image" &
  pid=$!; sleep 5
  if grab_window RegisImage /tmp/_regis_grab.png; then
    normalize /tmp/_regis_grab.png "$OUT/matterhorn-regis.png"
  fi
  kill "$pid" 2>/dev/null || true
fi
echo

# ---- kitty ---------------------------------------------------------------
# Kitty graphics protocol — xterm doesn't speak it, so this one runs in the
# `kitty` terminal itself (if installed) rather than xterm.
echo ">> kitty (KittyImage, Kitty graphics protocol)"
if command -v kitty >/dev/null; then
  if build kitty_image; then
    DEMO_SECONDS=10 CELL_PW=11 CELL_PH=22 \
      kitty --title KittyImage -o font_size="$FONT_SIZE" -o remember_window_size=no \
        -o initial_window_width=1100 -o initial_window_height=440 \
        -o background=black -o cursor_blink_interval=0 "$BUILD/kitty_image" &
    pid=$!; sleep 4
    if grab_window KittyImage /tmp/_kitty_grab.png; then
      normalize /tmp/_kitty_grab.png "$OUT/matterhorn-kitty.png"
    fi
    kill "$pid" 2>/dev/null || true
  fi
else
  echo "   skipped: 'kitty' terminal not found"
fi
echo

# ---- tektronix -----------------------------------------------------------
echo ">> tek (TekImage, Tektronix 4014 — separate window)"
if build tek_image; then
  TEK_FIT=1000 DEMO_SECONDS=12 \
    xterm -title TekImage -fa 'DejaVu Sans Mono' -fs "$FONT_SIZE" \
      -geometry "${COLS}x${ROWS}+50+50" -e "$BUILD/tek_image" &
  pid=$!; sleep 5
  # The drawing lands in xterm's SEPARATE Tek window, not the VT window.
  if grab_window 'tektronix(Tek)' /tmp/_tek_grab.png; then
    normalize /tmp/_tek_grab.png "$OUT/matterhorn-tek.png"
  fi
  kill "$pid" 2>/dev/null || true
fi
echo

echo "done:"
ls -la "$OUT"/matterhorn-sixel.png "$OUT"/matterhorn-regis.png \
       "$OUT"/matterhorn-kitty.png "$OUT"/matterhorn-tek.png 2>/dev/null | sed 's/^/  /'
