# Crysterm feature demos

Small, self-contained programs that each showcase one notable feature of
Crysterm, plus a script that records every one of them to an animated GIF so the
gallery can be regenerated whenever the framework or the demos change.

## Regenerate the GIFs

```sh
# from the repo root (or anywhere)
examples/feature-demos/make-gifs.sh                 # all demos, 80x15
examples/feature-demos/make-gifs.sh truecolor unicode   # just these

# everything is configurable via environment variables:
COLS=100 ROWS=30 DURATION=4 FPS=15 examples/feature-demos/make-gifs.sh
FONT_SIZE=24 SCALE=2 examples/feature-demos/make-gifs.sh   # larger / sharper
```

GIFs are written to `screenshots/features/<demo>.gif`.

**Requirements:** `crystal` (builds the demos) and `python3` with Pillow
(`PIL`). The recorder, `ttygif.py`, is bundled here and uses only the Python
standard library + Pillow — no external binaries and no network. It runs each
demo in a fixed-size pseudo-terminal (answering the terminal capability queries
a TUI sends), replays the output through a small built-in VT/ANSI emulator, and
renders the frames with a monospace font.

## The demos

| Demo | Feature it shows | GIF |
|------|------------------|-----|
| `concurrent_rendering.cr` | Single-threaded, **lock-free fiber rendering** — many widgets each animated by their own fiber; render requests coalesce into frames | `concurrent_rendering.gif` |
| `truecolor.cr` | **24-bit TrueColor** background sweep + **alpha-compositing** (translucent boxes and shadows blended in RGB) | `truecolor.gif` |
| `unicode.cr` | **Unicode / grapheme-aware** rendering: box-drawing, block elements, scripts, combining marks | `unicode.gif` |
| `mouse.cr` | **Dual-source unified mouse** — synthetic xterm- and gpm-sourced events flow through one `Event::Mouse` path | `mouse.gif` |
| `widgets.cr` | A slice of the **30+ widget library** (list, progress bar, checkboxes, button, text box, spinner, big text) | `widgets.gif` |
| `layout.cr` | **Layout engines**: `:grid` vs `:inline`/masonry, side by side | `layout.gif` |
| `image.cr` | **Image rendering as cells** — static PNG and an animated GIF decoded to TrueColor cells | `image.gif` |
| `styling.cr` | **Decorators & styling**: line/solid borders, drop shadows, bold/underline/inverse, 24-bit swatches | `styling.gif` |
| `terminfo.cr` | **No ncurses** — capability detection via `tput.cr` (unicode / truecolor / colors) | `terminfo.gif` |
| `events.cr` | **Event-driven architecture** — typed events with multiple independent subscribers | `events.gif` |
| `diff_rendering.cr` | **Cell-based diff drawing** — big static panel rendered every frame but drawn once (see the R/D/FPS overlay) | `diff_rendering.gif` |

### Showpieces (several features at once)

| Demo | What it shows | GIF |
|------|---------------|-----|
| `matrix.cr` | "Matrix" digital rain — full-screen recompose every frame, each glyph its own 24-bit fading-green tag | `matrix.gif` |
| `dashboard.cr` | A live system-monitor UI: labeled gauges, a data `Table`, and a scrolling activity log | `dashboard.gif` |
| `clock.cr` | A `BigText` digital clock with a seconds bar and date | `clock.gif` |
| `png_image.cr` | A full-color PNG (Grand Prismatic Spring) decoded to 24-bit cells, full-bleed | `png_image.png` (still) |
| `netscape.cr` | The classic **Netscape throbber** played two ways at once — **left fixed, right resizing** — to show animation + live resize. Sub-cell `Image::Glyph` (octant) by default; `BACKEND=kitty\|sixel\|iterm` for true-pixel graphics; `IMAGE=…` for any image | `netscape.gif` |
| `cracktro.cr` | An old-school "cracktro": copper bars, a color-cycling `BigText` logo, flashing greets, and a scroller | `cracktro.gif` |

### Sub-cell drawing modes (`Widget::Image::Glyph`)

`Image::Glyph` is a widget parallel to `Image::Ansi` that packs several sub-pixels
into one Unicode glyph to fake a higher rendering resolution than the cell grid.
`glyph_mode.cr` renders the **same Matterhorn photo** in each mode (chosen via
`GLYPH_MODE`); the build script emits one still PNG per mode so they can be
compared. Like `Image::Ansi`, every mode also supports animated GIF/APNG.

| Mode | Sub-grid | Colors | Output |
|------|----------|--------|--------|
| Block | 1×1 | 1 bg/cell | `matterhorn-block.png` |
| ASCII | 1×1 | color + edge-only contour glyphs | `matterhorn-ascii.png` |
| Half-block `▀` | 1×2 | 2/cell | `matterhorn-half.png` |
| Quadrant `▘▚▙` | 2×2 | 2/cell | `matterhorn-quadrant.png` |
| Sextant `🬞` (U+1FB00) | 2×3 | 2/cell | `matterhorn-sextant.png` |
| Octant `𜵑` (U+1CD00) | 2×4 | 2/cell | `matterhorn-octant.png` |
| Braille `⠿` | 2×4 | 1/cell (8 dots) | `matterhorn-braille.png` |

### Color depth (`Widget::Image::Ansi`)

`Image::Ansi` is natively TrueColor, but its `colors:` option quantizes the pixels
to a lower-color palette — the classic low-color look, and the way to render
correctly on terminals without 24-bit color. `ansi256_image.cr` renders the
Matterhorn in each, chosen via `ANSI_COLORS`:

| Mode | `ANSI_COLORS` | Output |
|------|---------------|--------|
| TrueColor (24-bit) | `truecolor` | (see `png_image.png`) |
| 256-color (xterm palette) | `c256` | `matterhorn-ansi-c256.png` |
| 16-color (ANSI palette) | `c16` | `matterhorn-ansi-c16.png` |

These are cell-based, so the normal `ttygif.py` recorder captures them — no
special terminal needed.

### Resizing & fit (all backends)

Every image backend renders into a box whose size may **vary at runtime**. The
shared design: each widget keeps the decoded image as a resolution-independent
*source* and derives the sized render lazily for the current box, re-sampling
(not re-decoding) when the box changes — driven at render time off the resolved
coordinates, so it tracks terminal resize, `%` reflow, layout and scroll alike.

A shared `Widget::Image::Fit` policy controls aspect handling for every backend:

| `fit:` | Behaviour |
|--------|-----------|
| `Stretch` (default) | fill the box exactly, distorting aspect |
| `Contain` | scale to fit inside the box, transparent letterbox margin |
| `Cover` | scale to fill the box, cropping the overflow |

`resize.cr` animates a box's size every frame and the image re-samples to fit
(`fit: Contain`); it's cell-based so the recorder captures it: `resize.gif`.
`resize_anim.cr` does the same with an **animated** GIF — playback continues
while the box resizes (`resize_anim.gif`). The graphics demos accept
`FIT=contain|cover|stretch` too (e.g. `FIT=contain ./make-graphics-shots.sh`).

Per-backend specifics: cell-grid and in-band raster backends re-sample from the
cached source; `Image::Overlay`/`Image::Ueberzug` re-place the overlay at the new
cell rect; `Image::Tek`'s separate window auto-rescales from the 4014 logical
space, so it only redraws on a parameter change.

**Animation** works on every backend that can do it — the cell-grid ones
(`Image::Ansi`, `Image::Glyph`) and the in-band graphics protocols (`Image::Sixel`,
`Image::Regis`, `Image::Kitty`); `Image::Iterm` hands the GIF to the terminal, which
animates it natively. Frames are composited once at a capped resolution (in a
background fiber, so a big GIF doesn't block first paint), then only the
*currently shown* frame is sampled to the box — lazily, cached per size — so a
resize re-samples one frame at a time instead of regenerating the whole
sequence (less work, less jitter). Kitty, being a separate layer the cells never
overdraw, is re-emitted only when the frame/size actually changes.

### Pixel & vector graphics (terminal-owned pixels)

Beyond the cell-grid renderers above, the **same Matterhorn photo** is rendered
several more ways where the *terminal* (or an external helper) owns the pixels
rather than Crysterm's cell buffer:

| Widget (demo) | How | Output |
|--------|-----|--------|
| `Image::Overlay` (`overlay_image.cr`) | shells out to `w3mimgdisplay`, painting the **actual image pixels** over the terminal window (no cells involved) | `matterhorn-overlay.png` |
| `Image::Ueberzug` (`ueberzug_image.cr`) | drives **Überzug / Überzug++** (JSON on stdin), the modern w3m successor, painting pixels in an X11 child window over the terminal | `matterhorn-ueberzug.png` |
| `Image::Sixel` (`sixel_image.cr`) | decodes + quantizes to a 252-color palette (Bayer-dithered) and emits an in-band **DCS sixel** raster sequence the terminal draws at the cursor | `matterhorn-sixel.png` |
| `Image::Regis` (`regis_image.cr`) | quantizes to ReGIS's built-in named colors and emits an in-band **ReGIS** vector stream (run-length horizontal vectors per scan line) | `matterhorn-regis.png` |
| `Image::Kitty` (`kitty_image.cr`) | transmits raw 32-bit RGBA (base64, chunked) in an in-band **Kitty graphics protocol** APC escape; full true-color, terminal-scaled to the cell box | `matterhorn-kitty.png` |
| `Image::Iterm` (`iterm_image.cr`) | base64s the **original file** in an in-band **iTerm2 `OSC 1337`** inline-image escape; full true-color, no decode/palette on our side | `matterhorn-iterm.png` |
| `Image::Tek` (`tek_image.cr`) | dithers to 1 bit and emits **Tektronix 4014** vectors; `ESC[?38h` switches xterm into Tek mode, drawn in a **separate** window | `matterhorn-tek.png` |

These are full pixel/vector graphics, but none works over a plain
pipe/pseudo-terminal (the `ttygif.py` recorder's VT emulator can't render them),
and each needs a capable terminal (or helper) on a real display:

* **sixel** — `xterm -ti vt340`, `foot`, `wezterm`, `mlterm`, …
* **ReGIS** — `xterm` built with `--enable-regis-graphics` (or a real VT340)
* **Kitty** — `kitty`, `wezterm`, `konsole`, `ghostty`, … (captured in `kitty` itself)
* **iTerm2** — `iTerm2`, `wezterm`, `konsole`, `mintty`, VS Code's terminal, … (captured in `konsole`)
* **Überzug** — the `ueberzug` or `ueberzugpp` binary on `PATH` (skipped if absent)
* **Tektronix** — `xterm` built with `--enable-tek4014` (opens its own window)

So the normal recorder can't capture them. `make-graphics-shots.sh` (and the
`Image::Overlay` path in `make-gifs.sh`) instead run each demo in a real `xterm`
on `$DISPLAY` and screenshot the window with `ffmpeg` — skipped automatically if
`DISPLAY`/`xterm`/`xwininfo`/`ffmpeg` aren't available. Run it with:

```
./make-graphics-shots.sh        # writes matterhorn-{sixel,regis,tek}.png
```

The image demos read their pictures from `screenshots/*.png` (downloaded from
Wikimedia Commons and cropped to the window's aspect by the maintainer); swap in
your own by replacing those files. The recorder draws the sub-cell glyph families
geometrically, so they render pixel-accurately even where the font lacks them.

Each demo runs until you press `q` (or Ctrl-Q); the recorder simply captures the
first few seconds (5s by default, set `DURATION`). Image assets used by `image.cr` live in `assets/` and
are generated by the snippet in the project history (a colorful PNG and a small
animated GIF).

### Seamless loops (`--mark`)

A demo with a slow warm-up or that should loop forever (e.g. `netscape`, which
composites a big GIF on first paint) records as a single **seamless loop**. The
demo, when run with `TTYGIF_MARK=1`, emits a per-frame out-of-band marker (an
APC string terminals ignore) carrying the frame index and its delay just before
drawing each frame; the recorder, run with `--mark`, films exactly the frames
between two loop starts — one output frame per source frame, timed by the source
delay. This skips the warm-up entirely (markers only begin once the demo is
animating), starts the GIF at the animation proper, and tiles with no visible
seam regardless of capture-timing jitter. `make-gifs.sh` does this automatically
for the demos listed in its `LOOP_DEMOS`.
