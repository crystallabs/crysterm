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
| `cracktro.cr` | An old-school "cracktro": copper bars, a color-cycling `BigText` logo, flashing greets, and a scroller | `cracktro.gif` |

### Sub-cell drawing modes (`Widget::GlyphImage`)

`GlyphImage` is a widget parallel to `ANSIImage` that packs several sub-pixels
into one Unicode glyph to fake a higher rendering resolution than the cell grid.
`glyph_mode.cr` renders the **same Matterhorn photo** in each mode (chosen via
`GLYPH_MODE`); the build script emits one still PNG per mode so they can be
compared. Like `ANSIImage`, every mode also supports animated GIF/APNG.

| Mode | Sub-grid | Colors | Output |
|------|----------|--------|--------|
| Block | 1×1 | 1 bg/cell | `matterhorn-block.png` |
| ASCII | 1×1 | color + edge-only contour glyphs | `matterhorn-ascii.png` |
| Half-block `▀` | 1×2 | 2/cell | `matterhorn-half.png` |
| Quadrant `▘▚▙` | 2×2 | 2/cell | `matterhorn-quadrant.png` |
| Sextant `🬞` (U+1FB00) | 2×3 | 2/cell | `matterhorn-sextant.png` |
| Octant `𜵑` (U+1CD00) | 2×4 | 2/cell | `matterhorn-octant.png` |
| Braille `⠿` | 2×4 | 1/cell (8 dots) | `matterhorn-braille.png` |

### Pixel & vector graphics (terminal-owned pixels)

Beyond the cell-grid renderers above, the **same Matterhorn photo** is rendered
four more ways where the *terminal* (or an external helper) owns the pixels
rather than Crysterm's cell buffer:

| Widget (demo) | How | Output |
|--------|-----|--------|
| `OverlayImage` (`overlay_image.cr`) | shells out to `w3mimgdisplay`, painting the **actual image pixels** over the terminal window (no cells involved) | `matterhorn-overlay.png` |
| `SixelImage` (`sixel_image.cr`) | decodes + quantizes to a 252-color palette (Bayer-dithered) and emits an in-band **DCS sixel** raster sequence the terminal draws at the cursor | `matterhorn-sixel.png` |
| `RegisImage` (`regis_image.cr`) | quantizes to ReGIS's built-in named colors and emits an in-band **ReGIS** vector stream (run-length horizontal vectors per scan line) | `matterhorn-regis.png` |
| `KittyImage` (`kitty_image.cr`) | transmits raw 32-bit RGBA (base64, chunked) in an in-band **Kitty graphics protocol** APC escape; full true-color, terminal-scaled to the cell box | `matterhorn-kitty.png` |
| `TekImage` (`tek_image.cr`) | dithers to 1 bit and emits **Tektronix 4014** vectors; `ESC[?38h` switches xterm into Tek mode, drawn in a **separate** window | `matterhorn-tek.png` |

These five are full pixel/vector graphics, but none works over a plain
pipe/pseudo-terminal (the `ttygif.py` recorder's VT emulator can't render them),
and each needs a capable terminal on a real display:

* **sixel** — `xterm -ti vt340`, `foot`, `wezterm`, `mlterm`, …
* **ReGIS** — `xterm` built with `--enable-regis-graphics` (or a real VT340)
* **Kitty** — `kitty`, `wezterm`, `konsole`, `ghostty`, … (the `make-graphics-shots.sh` capture runs this one in `kitty` itself, not xterm)
* **Tektronix** — `xterm` built with `--enable-tek4014` (opens its own window)

So the normal recorder can't capture them. `make-graphics-shots.sh` (and the
`OverlayImage` path in `make-gifs.sh`) instead run each demo in a real `xterm`
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
