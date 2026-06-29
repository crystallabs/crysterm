require "benchmark"
require "../src/crysterm"

# `Colors.blend` is the per-cell alpha/shadow blend: it runs PER CELL over
# shadow regions (`Screen#blend_region`, attr2 == nil) and over alpha widgets /
# media / docking (attr2 provided). Its `alpha` param is a `Float | Int` union
# for API generality, but every live caller passes a `Float64`.
#
# This benchmark exercises both shapes (shadow + alpha-widget) at screen scale.
# Use it to compare a candidate `Colors.blend` against the live one — the two
# loops below call the live method; to evaluate a change, edit src/colors.cr and
# re-run, comparing ips against the numbers recorded in the report.
#
# Run:  crystal run --release benchmarks/blend-attr.cr

include Crysterm

CELLS = 200 * 50

def rnd_attr(i : Int32) : Int64
  h = (i.to_u64 &* 2654435761_u64)
  fg = ((h >> 8) & 0xFFFFFF).to_i64
  bg = (h & 0xFFFFFF).to_i64
  flags = ((h >> 40) & Attr::FLAGS_MASK)
  Attr.pack(flags, fg, bg)
end

ATTRS = Array(Int64).new(CELLS) { |i| rnd_attr(i) }
UNDER = Array(Int64).new(CELLS) { |i| rnd_attr(i &* 7 &+ 3) }
SINK  = Array(Int64).new(CELLS, 0)

Benchmark.ips do |x|
  x.report("blend SHADOW (attr2=nil) x#{CELLS}") do
    i = 0
    while i < CELLS
      SINK.unsafe_put(i, Colors.blend(ATTRS.unsafe_fetch(i), alpha: 0.5))
      i += 1
    end
  end
  x.report("blend ALPHA  (attr2)     x#{CELLS}") do
    i = 0
    while i < CELLS
      SINK.unsafe_put(i, Colors.blend(ATTRS.unsafe_fetch(i), UNDER.unsafe_fetch(i), alpha: 0.5))
      i += 1
    end
  end
end

puts "\n(sink guard: #{SINK.unsafe_fetch(CELLS - 1)})"
