#!/usr/bin/env bash
# make-graphics-shots.sh — capture the image backends that the built-in headless
# capture CANNOT do, beside each demo as tests/widget/media/<backend>/<backend>.png.
#
# Most image backends need NO external capture: `Window#capture` (used by
# tools/test.cr) composites the cell buffer AND the in-band terminal-graphics
# backends (sixel / kitty / iterm / regis) into the PNG/APNG in-process, and the
# cell-based `ansi` (TrueColor/C256/C16/C8) and `glyph` (block/half/quadrant/
# sextant/octant/braille/ascii) variants render straight into cells — so all of
# those are captured headlessly on any platform (incl. macOS) by the normal:
#
#     crystal run tools/test.cr -- --force tests/widget/media
#
# Only THREE backends fall outside that, because their pixels never reach
# Crysterm's buffer:
#   * tek      — Tektronix 4014 draws in xterm's SEPARATE Tek window
#   * overlay  — Media::Overlay shells out to w3mimgdisplay (external X overlay)
#   * ueberzug — Media::Ueberzug shells out to überzug (external X overlay)
# Those three are what this script handles: run the demo in a REAL terminal on an
# X display and screenshot the window.
#
# Pass backend names to render only some, e.g.:  make-graphics-shots.sh tek
#
# Requirements (an X11 stack):
#   * $DISPLAY + xterm (Tek/overlay use it; built with --enable-tek4014 for tek)
#   * xwininfo  (locate the window)
#   * ImageMagick `import`  (grab the window) — preferred; falls back to
#     `ffmpeg -f x11grab` where ImageMagick has no X support
#   * python3 + Pillow  (normalize the grab to a uniform size)
#   * w3mimgdisplay (overlay) / ueberzug|ueberzugpp (ueberzug)
#
# macOS: works under **XQuartz** (install XQuartz for the X server + xterm/
# xwininfo and ImageMagick for `import`; macOS ffmpeg has no x11grab, hence
# `import`). The native iTerm2/kitty + `screencapture` route is NOT automated
# here — but it isn't needed for these three: tek has no macOS terminal, and the
# overlays are X11-only by nature.
#
# Each demo self-terminates via its *_SECONDS knob, so no broad pkill is needed.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
MEDIA="$ROOT/tests/widget/media"          # demos live at $MEDIA/<backend>/<backend>.cr
BUILD="${BUILD:-/tmp/_crysterm_gfx_build}"
mkdir -p "$BUILD"

COLS="${COLS:-80}"
ROWS="${ROWS:-15}"
FONT_SIZE="${FONT_SIZE:-18}"
OUT_W="${OUT_W:-880}"
OUT_H="${OUT_H:-330}"

WANT=("$@")
want() {  # want <backend> -> true if it should run
  [ "${#WANT[@]}" -eq 0 ] && return 0
  local x; for x in "${WANT[@]}"; do [ "$x" = "$1" ] && return 0; done
  return 1
}

# Where a backend's still goes — beside its demo, matching tools/test.cr naming.
outpng() { echo "$MEDIA/$1/$1.png"; }

# Need an X display + xterm + xwininfo + a grabber (import OR ffmpeg-x11grab).
have_grabber() { command -v import >/dev/null || command -v ffmpeg >/dev/null; }
if [ -z "${DISPLAY:-}" ] || ! command -v xterm >/dev/null \
   || ! command -v xwininfo >/dev/null || ! have_grabber; then
  if [ "$(uname)" = Darwin ]; then
    cat >&2 <<'MSG'
skipped: tek/overlay/ueberzug are captured by running the demo in a real X
terminal and screenshotting its window — this needs an X11 stack.
On macOS: install XQuartz (X server + xterm + xwininfo) and ImageMagick (`import`),
launch from an XQuartz session ($DISPLAY set), then re-run.
All OTHER image backends (ansi & glyph variants, sixel/kitty/iterm/regis) are
captured headlessly:  crystal run tools/test.cr -- --force tests/widget/media
MSG
  else
    echo "skipped: needs DISPLAY, xterm, xwininfo and import (ImageMagick) or ffmpeg" >&2
  fi
  exit 0
fi

# ---- image post-processing (Pillow) --------------------------------------

normalize() {  # normalize <src.png> <dst.png>  — resize to OUT_W x OUT_H
  python3 - "$1" "$2" "$OUT_W" "$OUT_H" <<'PY'
import sys
from PIL import Image
src, dst, w, h = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
Image.open(src).convert("RGB").resize((w, h), Image.LANCZOS).save(dst)
print("   wrote", dst, (w, h))
PY
}

normalize_trim() {  # like normalize() but crop any pure-black letterbox first (Tek)
  python3 - "$1" "$2" "$OUT_W" "$OUT_H" <<'PY'
import sys
from PIL import Image, ImageChops
src, dst, W, H = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
im = Image.open(src).convert("RGB")
bbox = ImageChops.difference(im, Image.new("RGB", im.size, (0, 0, 0))).getbbox()
if bbox: im = im.crop(bbox)
im.resize((W, H), Image.LANCZOS).save(dst)
print("   wrote", dst, (W, H))
PY
}

# ---- window grab (X11; portable: import preferred, ffmpeg fallback) --------

grab_window() {  # grab_window <wm-name> <out.png>
  local name="$1" dst="$2" info id gx gy gw gh
  info=$(xwininfo -name "$name" 2>/dev/null || true)
  if [ -z "$info" ]; then echo "   could not locate window '$name'"; return 1; fi
  if command -v import >/dev/null; then
    id=$(awk '/Window id:/{print $4; exit}' <<<"$info")
    import -window "$id" "$dst"
  else
    gx=$(awk '/Absolute upper-left X/{print $4}' <<<"$info")
    gy=$(awk '/Absolute upper-left Y/{print $4}' <<<"$info")
    gw=$(awk '/Width:/{print $2}' <<<"$info")
    gh=$(awk '/Height:/{print $2}' <<<"$info")
    [ -z "$gw" ] && { echo "   no geometry for '$name'"; return 1; }
    ffmpeg -hide_banner -loglevel error -f x11grab -video_size "${gw}x${gh}" \
      -i "${DISPLAY}+${gx},${gy}" -frames:v 1 -y "$dst"
  fi
}

build() {  # build <backend>  -> $BUILD/<backend>
  local b="$1" src="$MEDIA/$1/$1.cr"
  if [ ! -f "$src" ]; then echo "   no demo: ${src#$ROOT/}"; return 1; fi
  echo "   building $b ..."
  crystal build "$src" -o "$BUILD/$b" 2>&1 | sed 's/^/   /'
  return "${PIPESTATUS[0]}"
}

# ---- overlay -------------------------------------------------------------
echo ">> overlay (Media::Overlay, w3mimgdisplay external X overlay)"
if want overlay; then
  if command -v w3mimgdisplay >/dev/null || [ -x /usr/lib/w3m/w3mimgdisplay ]; then
    if build overlay; then
      PATH="$PATH:/usr/lib/w3m" OVERLAY_SECONDS=12 \
        xterm -title Overlay -fa 'DejaVu Sans Mono' -fs "$FONT_SIZE" \
          -geometry "${COLS}x${ROWS}+50+50" -e "$BUILD/overlay" &
      pid=$!; sleep 5
      if grab_window Overlay /tmp/_overlay_grab.png; then
        normalize /tmp/_overlay_grab.png "$(outpng overlay)"
      fi
      kill "$pid" 2>/dev/null || true
    fi
  else
    echo "   skipped: w3mimgdisplay not found"
  fi
fi
echo

# ---- ueberzug ------------------------------------------------------------
echo ">> ueberzug (Media::Ueberzug, überzug external X overlay)"
if want ueberzug; then
  if command -v ueberzug >/dev/null || command -v ueberzugpp >/dev/null; then
    if build ueberzug; then
      DEMO_SECONDS=11 \
        xterm -title Ueberzug -fa 'DejaVu Sans Mono' -fs "$FONT_SIZE" \
          -geometry "${COLS}x${ROWS}+50+50" -e "$BUILD/ueberzug" &
      pid=$!; sleep 5
      if grab_window Ueberzug /tmp/_ueberzug_grab.png; then
        normalize /tmp/_ueberzug_grab.png "$(outpng ueberzug)"
      fi
      kill "$pid" 2>/dev/null || true
    fi
  else
    echo "   skipped: 'ueberzug'/'ueberzugpp' binary not found"
  fi
fi
echo

# ---- tektronix -----------------------------------------------------------
echo ">> tek (Media::Tek, Tektronix 4014 — separate xterm window)"
if want tek && build tek; then
  DEMO_SECONDS=12 \
    xterm -title Tek -fa 'DejaVu Sans Mono' -fs "$FONT_SIZE" \
      -geometry "${COLS}x${ROWS}+50+50" -e "$BUILD/tek" &
  pid=$!; sleep 5
  # The drawing lands in xterm's SEPARATE Tek window, not the VT window.
  if grab_window 'tektronix(Tek)' /tmp/_tek_grab.png; then
    normalize_trim /tmp/_tek_grab.png "$(outpng tek)"
  fi
  kill "$pid" 2>/dev/null || true
fi
echo

echo "done:"
for b in overlay ueberzug tek; do
  f="$(outpng "$b")"; [ -f "$f" ] && ls -la "$f" | sed 's/^/  /'
done
echo "  (ansi/sixel/kitty/iterm/regis are captured headlessly by tools/test.cr)"
