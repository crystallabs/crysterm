require "benchmark"
require "../src/crysterm"

# Isolates the `Media::Cells` per-cell paint hot path (`draw_sample` →
# `paint`/`paint_two_color`/`paint_braille`/`paint_cell`) for the cell-grid image
# backends (`Media::Ansi`, `Media::Glyph`). A media widget caches its sampled
# bitmap per box size, so every animation frame / re-render re-runs `draw_sample`
# over the content cells — that's the path measured here. Build a screen, attach
# a backend with an injected bitmap (no decode), let the first render build+cache
# the sample, then time repeated renders.
#
# Run:  crystal run --release benchmarks/media-compose.cr

include Crysterm

COLS  =  120
ROWS  =   48
RONDS = 2000

# A synthetic RGBA bitmap at native resolution for a COLS x ROWS content box.
def make_bitmap(w : Int32, h : Int32) : PNGGIF::Bitmap
  Array(Array(PNGGIF::Pixel)).new(h) do |y|
    Array(PNGGIF::Pixel).new(w) do |x|
      r = ((x * 7 + y * 3) & 0xff).to_u8
      g = ((x * 3 + y * 5) & 0xff).to_u8
      b = ((x * 11 + y * 2) & 0xff).to_u8
      a = (((x + y) % 9 == 0) ? 0_u8 : 255_u8) # a few transparent cells
      PNGGIF::Pixel.new(r, g, b, a)
    end
  end
end

def bench(label, widget)
  s = Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
  s.append widget
  widget.render # build + cache the sample for the box
  GC.collect
  before = GC.stats.total_bytes
  t0 = Time.instant
  RONDS.times { widget.render }
  dt = Time.instant - t0
  alloc = GC.stats.total_bytes - before
  printf "%-28s %8.1f µs/render   %8.0f B/render\n",
    label, dt.total_microseconds / RONDS, alloc.to_f / RONDS
end

ansi = Widget::Media::Ansi.new width: COLS, height: ROWS, animate: false
ansi.bitmap = make_bitmap COLS, ROWS
bench "Ansi (1 cell/pixel)", ansi

{Widget::Media::Glyph::Mode::Half,
 Widget::Media::Glyph::Mode::Quadrant,
 Widget::Media::Glyph::Mode::Octant,
 Widget::Media::Glyph::Mode::Braille}.each do |mode|
  sx, sy = mode.subgrid
  g = Widget::Media::Glyph.new mode: mode, width: COLS, height: ROWS, animate: false
  g.bitmap = make_bitmap COLS * sx, ROWS * sy
  bench "Glyph #{mode}", g
end

# --- E1: per-streamed-frame video-source bitmap construction --------------
# The streaming decoder turns a raw RGBA `@buf` into a `PNGGIF::Bitmap` every
# tick. Old path allocated a fresh h-array-of-w-arrays bitmap per frame
# (`to_bitmap`); the ping-pong path fills two preallocated buffers in place.
VS = Widget::Media::VideoSource
VW = 320
VH = 180
vbuf = Bytes.new(VW * VH * 4)
VW.times { |i| vbuf[i] = (i & 0xff).to_u8 }

def alloc_bench(label, iters = 2000, &)
  yield # warm
  GC.collect
  before = GC.stats.total_bytes
  t0 = Time.instant
  iters.times { yield }
  dt = Time.instant - t0
  alloc = GC.stats.total_bytes - before
  printf "%-28s %8.1f µs/frame   %8.0f B/frame\n",
    label, dt.total_microseconds / iters, alloc.to_f / iters
end

alloc_bench "E1 to_bitmap (old, alloc)" { VS.to_bitmap vbuf, VW, VH }

pa = VS.blank_bitmap VW, VH
pb = VS.blank_bitmap VW, VH
toggle = false
alloc_bench "E1 ping-pong (new, reuse)" do
  toggle = !toggle
  VS.fill_bitmap (toggle ? pa : pb), vbuf, VW, VH
end

# --- E2: compose exact-fit early-return vs letterbox place_at -------------
srcbmp = make_bitmap 200, 200
srcpng = PNGGIF::PNG.from_frames([{srcbmp, 100}], 200, 200)
alloc_bench "E2 compose Stretch (early)" { Widget::Media::Fitting.compose srcpng, srcbmp, COLS, ROWS, Widget::Media::Fit::Stretch }
alloc_bench "E2 compose Contain (place_at)" { Widget::Media::Fitting.compose srcpng, srcbmp, COLS, ROWS, Widget::Media::Fit::Contain }
