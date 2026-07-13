require "benchmark"
require "../src/crysterm"

# Isolates the in-band graphics **encode** hot path (`Media::Sixel#encode`,
# `Media::Kitty#encode`), which a per-frame-re-encoding graphic (streaming video,
# an animated `Graph::Canvas` chart/donut) runs every frame. Compares the
# per-frame scratch allocation with `media.reuse_buffers` OFF (fresh buffers each
# frame — the baseline) vs ON (persistent scratch reused across frames), and
# asserts the emitted payload is byte-identical either way.
#
# Run:  crystal run --release benchmarks/media-encode.cr

include Crysterm

COLS  = 40
ROWS  = 12
CPW   = 10
CPH   = 20
PW    = COLS * CPW # 400
PH    = ROWS * CPH # 240
RONDS = 1000

def make_bitmap(w : Int32, h : Int32) : PNGGIF::Bitmap
  Array(Array(PNGGIF::Pixel)).new(h) do |y|
    Array(PNGGIF::Pixel).new(w) do |x|
      r = ((x * 7 + y * 3) & 0xff).to_u8
      g = ((x * 3 + y * 5) & 0xff).to_u8
      b = ((x * 11 + y * 2) & 0xff).to_u8
      a = (((x + y) % 9 == 0) ? 0_u8 : 255_u8) # a few transparent pixels
      PNGGIF::Pixel.new(r, g, b, a)
    end
  end
end

def bench(label, &block : -> String)
  block.call # warm
  GC.collect
  before = GC.stats.total_bytes
  t0 = Time.instant
  RONDS.times { block.call }
  dt = Time.instant - t0
  alloc = GC.stats.total_bytes - before
  printf "%-34s %9.1f µs/frame   %10.0f B/frame\n",
    label, dt.total_microseconds / RONDS, alloc.to_f / RONDS
end

BMP = make_bitmap PW, PH

# ---- Sixel ----------------------------------------------------------------
sx = Widget::Media::Sixel.new width: COLS, height: ROWS, animate: false
sx.dither = Widget::Media::Dither::Ordered # animation/video case (frame-stable)

Config.media_reuse_buffers = false
off = sx.encode BMP, PW, PH, 0, 0, COLS, ROWS
Config.media_reuse_buffers = true
on = sx.encode BMP, PW, PH, 0, 0, COLS, ROWS
puts "Sixel correctness: identical = #{off == on}  (expect true), bytes = #{off.bytesize}"

Config.media_reuse_buffers = false
bench("Sixel encode  reuse=OFF") { sx.encode BMP, PW, PH, 0, 0, COLS, ROWS }
Config.media_reuse_buffers = true
bench("Sixel encode  reuse=ON ") { sx.encode BMP, PW, PH, 0, 0, COLS, ROWS }

puts

# ---- Sixel, Diffusion (still) ---------------------------------------------
sx.dither = Widget::Media::Dither::Diffusion
Config.media_reuse_buffers = false
doff = sx.encode BMP, PW, PH, 0, 0, COLS, ROWS
Config.media_reuse_buffers = true
don = sx.encode BMP, PW, PH, 0, 0, COLS, ROWS
puts "Sixel(diffusion) correctness: identical = #{doff == don}  (expect true)"

Config.media_reuse_buffers = false
bench("Sixel(diff) encode  reuse=OFF") { sx.encode BMP, PW, PH, 0, 0, COLS, ROWS }
Config.media_reuse_buffers = true
bench("Sixel(diff) encode  reuse=ON ") { sx.encode BMP, PW, PH, 0, 0, COLS, ROWS }

puts

# ---- Kitty ----------------------------------------------------------------
kt = Widget::Media::Kitty.new width: COLS, height: ROWS, animate: false
Config.media_reuse_buffers = false
koff = kt.encode BMP, PW, PH, 0, 0, COLS, ROWS
Config.media_reuse_buffers = true
kon = kt.encode BMP, PW, PH, 0, 0, COLS, ROWS
puts "Kitty correctness: identical = #{koff == kon}  (expect true), bytes = #{koff.bytesize}"

Config.media_reuse_buffers = false
bench("Kitty encode  reuse=OFF") { kt.encode BMP, PW, PH, 0, 0, COLS, ROWS }
Config.media_reuse_buffers = true
bench("Kitty encode  reuse=ON ") { kt.encode BMP, PW, PH, 0, 0, COLS, ROWS }
