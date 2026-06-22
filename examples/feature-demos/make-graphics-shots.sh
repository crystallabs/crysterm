#!/usr/bin/env bash
# Capture still PNGs of the terminal-graphics image demos (sixel, ReGIS,
# Tektronix) into screenshots/features/.
#
# These can't go through the ttygif.py pseudo-terminal recorder: its built-in VT
# emulator doesn't implement sixel/ReGIS/Tek (just as it can't show the w3m
# overlay). So — exactly like the Image::Overlay path in make-gifs.sh — we run
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

# Like normalize(), but first trims any pure-black border. Used for the Tek
# window: a source whose aspect differs from the ~4:3 Tek screen is letterboxed
# with black, so trimming it keeps the image filling the final frame regardless
# of the source's proportions.
normalize_trim() {
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

# Like normalize(), but first strips Konsole's chrome: the light top toolbar and
# the right scrollbar. Their exact pixel size depends on the Konsole/Qt theme, so
# we DETECT them (the chrome is light grey; the terminal content — dark title bar
# + image — is not) rather than hardcoding a fragile offset.
normalize_konsole() {
  python3 - "$1" "$2" "$OUT_W" "$OUT_H" <<'PY'
import sys
from PIL import Image
src, dst, W, H = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
im = Image.open(src).convert("RGB"); w, h = im.size; px = im.load()
def light(p): r, g, b = p; return r > 180 and g > 180 and b > 180
def row_light(y): xs = range(0, w, 4); return sum(light(px[x, y]) for x in xs) / len(xs)
def col_light(x, top): ys = range(top, h, 4); return sum(light(px[x, y]) for y in ys) / len(ys)
top = next((y for y in range(h) if row_light(y) < 0.5), 0)        # toolbar bottom
right = next((x + 1 for x in range(w - 1, -1, -1) if col_light(x, top) < 0.5), w)  # scrollbar left
im.crop((0, top, right, h)).resize((W, H), Image.LANCZOS).save(dst)
print("   wrote", dst, (W, H), "(konsole chrome: top=%d right=%d)" % (top, right))
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
echo ">> sixel (Image::Sixel, in-band DCS raster)"
if build sixel_image; then
  # maxGraphicSize must exceed the sixel's pixel size or xterm silently drops it.
  # No CELL_PW/PH: the demo auto-detects the real cell size (TIOCGWINSZ) so the
  # raster matches the window exactly instead of leaving a black margin.
  DEMO_SECONDS=10 \
    xterm -title Sixel -fa 'DejaVu Sans Mono' -fs "$FONT_SIZE" \
      -geometry "${COLS}x${ROWS}+50+50" -ti vt340 \
      -xrm 'XTerm*numColorRegisters: 256' -xrm 'XTerm*maxGraphicSize: 4000x4000' \
      -e "$BUILD/sixel_image" &
  pid=$!; sleep 4
  if grab_window Sixel /tmp/_sixel_grab.png; then
    normalize /tmp/_sixel_grab.png "$OUT/matterhorn-sixel.png"
  fi
  kill "$pid" 2>/dev/null || true
fi
echo

# ---- regis ---------------------------------------------------------------
echo ">> regis (Image::Regis, in-band ReGIS vectors)"
if build regis_image; then
  # xterm maps its ReGIS logical screen (regisScreenSize, in pixels) onto the
  # window ~1:1, so it must equal the window's real pixel size or the image is
  # left in a corner with a black margin. We don't know that until the window
  # exists, so: launch once to read it (xwininfo), then relaunch with a matching
  # regisScreenSize AND the same REGIS_W/H so the demo's logical space lines up.
  probe=$(xterm -title RegisProbe -fa 'DejaVu Sans Mono' -fs "$FONT_SIZE" \
            -geometry "${COLS}x${ROWS}+50+50" -ti vt340 -e sleep 6 & \
          pp=$!; sleep 2; xwininfo -name RegisProbe 2>/dev/null; kill "$pp" 2>/dev/null)
  gw=$(awk '/Width:/{print $2}' <<<"$probe"); gh=$(awk '/Height:/{print $2}' <<<"$probe")
  gw=${gw:-1204}; gh=${gh:-454}
  REGIS_W="$gw" REGIS_H="$gh" DEMO_SECONDS=12 \
    xterm -title Regis -fa 'DejaVu Sans Mono' -fs "$FONT_SIZE" \
      -geometry "${COLS}x${ROWS}+50+50" -ti vt340 \
      -xrm 'XTerm*numColorRegisters: 256' -xrm "XTerm*regisScreenSize: ${gw}x${gh}" \
      -e "$BUILD/regis_image" &
  pid=$!; sleep 5
  if grab_window Regis /tmp/_regis_grab.png; then
    normalize /tmp/_regis_grab.png "$OUT/matterhorn-regis.png"
  fi
  kill "$pid" 2>/dev/null || true
fi
echo

# ---- kitty ---------------------------------------------------------------
# Kitty graphics protocol — xterm doesn't speak it, so this one runs in the
# `kitty` terminal itself (if installed) rather than xterm.
echo ">> kitty (Image::Kitty, Kitty graphics protocol)"
if command -v kitty >/dev/null; then
  if build kitty_image; then
    DEMO_SECONDS=10 \
      kitty --title Kitty -o font_size="$FONT_SIZE" -o remember_window_size=no \
        -o initial_window_width=1100 -o initial_window_height=440 \
        -o background=black -o cursor_blink_interval=0 "$BUILD/kitty_image" &
    pid=$!; sleep 4
    if grab_window Kitty /tmp/_kitty_grab.png; then
      normalize /tmp/_kitty_grab.png "$OUT/matterhorn-kitty.png"
    fi
    kill "$pid" 2>/dev/null || true
  fi
else
  echo "   skipped: 'kitty' terminal not found"
fi
echo

# ---- iterm2 --------------------------------------------------------------
# iTerm2 inline-images protocol — captured in Konsole (xterm doesn't speak it).
echo ">> iterm (Image::Iterm, iTerm2 OSC 1337 inline images)"
if command -v konsole >/dev/null; then
  if build iterm_image; then
    DEMO_SECONDS=11 konsole -p tabtitle=Iterm --hide-menubar --hide-tabbar \
      --geometry 900x380+50+50 -e "$BUILD/iterm_image" &
    pid=$!; sleep 5
    if grab_window 'Iterm — Konsole' /tmp/_iterm_grab.png; then
      normalize_konsole /tmp/_iterm_grab.png "$OUT/matterhorn-iterm.png"
    fi
    kill "$pid" 2>/dev/null || true
  fi
else
  echo "   skipped: 'konsole' (or another iTerm2-capable terminal) not found"
fi
echo

# ---- ueberzug ------------------------------------------------------------
# Überzug / Überzug++ overlay — needs the helper binary; otherwise skipped.
echo ">> ueberzug (Image::Ueberzug, überzug X11 overlay)"
if command -v ueberzug >/dev/null || command -v ueberzugpp >/dev/null; then
  if build ueberzug_image; then
    DEMO_SECONDS=11 \
      xterm -title Ueberzug -fa 'DejaVu Sans Mono' -fs "$FONT_SIZE" \
        -geometry "${COLS}x${ROWS}+50+50" -e "$BUILD/ueberzug_image" &
    pid=$!; sleep 5
    if grab_window Ueberzug /tmp/_ueberzug_grab.png; then
      normalize /tmp/_ueberzug_grab.png "$OUT/matterhorn-ueberzug.png"
    fi
    kill "$pid" 2>/dev/null || true
  fi
else
  echo "   skipped: 'ueberzug'/'ueberzugpp' binary not found"
fi
echo

# ---- ansi palette stills (256 / 16 color) --------------------------------
# Cell-based, so the normal ttygif.py recorder renders them (no real terminal).
echo ">> ansi palette (Image::Ansi 256/16-color quantization)"
if build ansi256_image; then
  for m in c256 c16; do
    ANSI_COLORS="$m" python3 "$HERE/ttygif.py" \
      --out "$OUT/matterhorn-ansi-$m.png" --cols "$COLS" --rows "$ROWS" \
      --duration 4 --fps 8 --font-size "$FONT_SIZE" --scale 1 \
      -- "$BUILD/ansi256_image" 2>&1 | sed 's/^/   /'
  done
fi
echo

# ---- tektronix -----------------------------------------------------------
echo ">> tek (Image::Tek, Tektronix 4014 — separate window)"
if build tek_image; then
  TEK_FIT=1000 DEMO_SECONDS=12 \
    xterm -title Tek -fa 'DejaVu Sans Mono' -fs "$FONT_SIZE" \
      -geometry "${COLS}x${ROWS}+50+50" -e "$BUILD/tek_image" &
  pid=$!; sleep 5
  # The drawing lands in xterm's SEPARATE Tek window, not the VT window.
  if grab_window 'tektronix(Tek)' /tmp/_tek_grab.png; then
    normalize_trim /tmp/_tek_grab.png "$OUT/matterhorn-tek.png"
  fi
  kill "$pid" 2>/dev/null || true
fi
echo

echo "done:"
ls -la "$OUT"/matterhorn-sixel.png "$OUT"/matterhorn-regis.png \
       "$OUT"/matterhorn-kitty.png "$OUT"/matterhorn-iterm.png \
       "$OUT"/matterhorn-ueberzug.png "$OUT"/matterhorn-ansi-c256.png \
       "$OUT"/matterhorn-ansi-c16.png "$OUT"/matterhorn-tek.png 2>/dev/null | sed 's/^/  /'
