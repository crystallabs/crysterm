require "benchmark"
require "../src/crysterm"

# `Colors.composite` folds an overlay plane's cell over the base cell, per the
# cell's per-channel `Attr::Alpha` mode. It runs PER CELL in the plane
# compositor (`Plane#composite_onto`) over every painted cell of an overlay
# (popups, alpha widgets, media). The overwhelmingly common painted cell is
# fully **Opaque/Opaque** (a normal solid overlay), for which the result is just
# `top` with its alpha/reserved bits cleared.
#
# This benchmark compares the current `Colors.composite` against a candidate
# that fast-paths the Opaque/Opaque case to a single mask, and asserts they
# agree bit-for-bit across a mix of alpha modes.
#
# Run:  crystal run --release benchmarks/composite-cells.cr

include Crysterm

# OLD (pre-optimization) `composite`: always runs both `composite_field`s and
# `pack`, even for a fully-opaque cell. The live `Colors.composite` now
# fast-paths the Opaque/Opaque case to a single mask; this replica lets the
# harness show the before/after.
def composite_old(top : Int64, under : Int64) : Int64
  fg = Colors.composite_field(Attr.fg_alpha(top), Attr.fg(top), Attr.fg(under), true)
  bg = Colors.composite_field(Attr.bg_alpha(top), Attr.bg(top), Attr.bg(under), false)
  Attr.pack(Attr.flags(top), fg, bg)
end

# ---- Build a realistic cell mix --------------------------------------------
CELLS = 200 * 50

def rnd_attr(i : Int32) : Int64
  h = (i.to_u64 &* 2654435761_u64)
  fg = ((h >> 8) & 0xFFFFFF).to_i64
  bg = (h & 0xFFFFFF).to_i64
  flags = ((h >> 40) & Attr::FLAGS_MASK)
  Attr.pack(flags, fg, bg)
end

TOPS  = Array(Int64).new(CELLS) { |i| rnd_attr(i) }
UNDER = Array(Int64).new(CELLS) { |i| rnd_attr(i &* 7 &+ 3) }

# Assign alpha modes: ~85% fully Opaque (the common solid overlay), the rest a
# mix of Blend / Transparent / HighContrast on one or both channels.
CELLS.times do |i|
  case i % 20
  when 17 then TOPS[i] = Attr.with_alpha(TOPS[i], Attr::Alpha::Blend, Attr::Alpha::Blend)
  when 18 then TOPS[i] = Attr.with_alpha(TOPS[i], Attr::Alpha::Transparent, Attr::Alpha::Opaque)
  when 19 then TOPS[i] = Attr.with_alpha(TOPS[i], Attr::Alpha::Opaque, Attr::Alpha::HighContrast)
  else         TOPS[i] # Opaque/Opaque
  end
end

# ---- Correctness ------------------------------------------------------------
mismatch = 0
CELLS.times do |i|
  a = Colors.composite(TOPS.unsafe_fetch(i), UNDER.unsafe_fetch(i))
  b = composite_old(TOPS.unsafe_fetch(i), UNDER.unsafe_fetch(i))
  mismatch += 1 if a != b
end
puts "correctness: mismatches = #{mismatch}  (expect 0)"
puts

SINK = Array(Int64).new(CELLS, 0)

Benchmark.ips do |x|
  x.report("composite OLD (replica)  x#{CELLS}/pass") do
    i = 0
    while i < CELLS
      SINK.unsafe_put(i, composite_old(TOPS.unsafe_fetch(i), UNDER.unsafe_fetch(i)))
      i += 1
    end
  end
  x.report("composite NEW (live)     x#{CELLS}/pass") do
    i = 0
    while i < CELLS
      SINK.unsafe_put(i, Colors.composite(TOPS.unsafe_fetch(i), UNDER.unsafe_fetch(i)))
      i += 1
    end
  end
end

puts "\n(sink guard: #{SINK.unsafe_fetch(CELLS - 1)})"
