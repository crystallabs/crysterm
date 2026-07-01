require "benchmark"
require "../lib/term_colors/src/term_colors"

# `TermColors#mix` is the per-channel RGB blend behind `Colors.blend`/`tint` and
# `Plane#composite_onto` — runs per cell on every shadow, tint, alpha widget,
# and plane composite. The old form did three Float64 multiplies plus three
# float->int truncations per call, with `alpha` as a `Float | Int` union
# (blocking monomorphization). The new form precomputes `(1 - alpha)` as a
# 16-bit fixed-point weight and does pure integer math per channel.
#
# Runs OLD (float) and NEW (integer) side by side and asserts they agree:
# bit-exact at alpha 0.5, within 1/255 per channel for arbitrary alpha.
#
# Run:  crystal run --release benchmarks/blend-mix.cr

include TermColors

def mix_old(c1 : Int, c2 : Int, alpha = 0.5) : Int32
  r1 = (c1 >> 16) & 0xff; g1 = (c1 >> 8) & 0xff; b1 = c1 & 0xff
  r2 = (c2 >> 16) & 0xff; g2 = (c2 >> 8) & 0xff; b2 = c2 & 0xff

  r = (r1 + ((r2 - r1) * (1 - alpha))).to_i & 0xff
  g = (g1 + ((g2 - g1) * (1 - alpha))).to_i & 0xff
  b = (b1 + ((b2 - b1) * (1 - alpha))).to_i & 0xff

  (r << 16) | (g << 8) | b
end

# `mix` (NEW, integer) is the live method from the required term_colors above.
def mix_new(c1, c2, alpha = 0.5)
  mix c1, c2, alpha
end

# ---- Correctness: NEW vs OLD across the color cube & many alphas -------------

max_channel_diff = 0
exact_at_half = true
step = 17 # walk 0,17,...,255 per channel (16^3 pairs) — enough coverage
{0.0, 0.25, 0.5, 0.75, 1.0, 0.3, 0.1, 0.9}.each do |a|
  r1 = 0
  while r1 <= 255
    g1 = 0
    while g1 <= 255
      b1 = 0
      while b1 <= 255
        c1 = (r1 << 16) | (g1 << 8) | b1
        c2 = ((255 - r1) << 16) | ((255 - g1) << 8) | (255 - b1)
        o = mix_old(c1, c2, a)
        n = mix_new(c1, c2, a)
        {16, 8, 0}.each do |sh|
          d = (((o >> sh) & 0xff) - ((n >> sh) & 0xff)).abs
          max_channel_diff = d if d > max_channel_diff
          exact_at_half = false if a == 0.5 && d != 0
        end
        b1 += step
      end
      g1 += step
    end
    r1 += step
  end
end

puts "correctness:"
puts "  bit-exact at alpha 0.5:        #{exact_at_half}"
puts "  max per-channel diff (any a):  #{max_channel_diff}  (expect <= 1)"
puts

# ---- Throughput: a full-screen shadow/tint pass (per-cell blend) ------------
#
# Each iteration feeds the previous result into the next call's inputs
# (loop-carried dependency), preventing dead-code-elimination/vectorization.

CELLS  = 200 * 50 # a 200x50 terminal
COLORS = Array(Int32).new(CELLS) { |i| ((i.to_u64 &* 2654435761_u64) & 0xFFFFFF_u64).to_i32 }
# Stores every blended cell; the memory write is a side effect the optimizer
# must keep. Read after the benchmark so it isn't itself dead.
SINK = Array(Int32).new(CELLS, 0)

Benchmark.ips do |x|
  x.report("mix OLD (float)   x#{CELLS}/pass") do
    i = 0
    acc = 0x7f7f7f
    while i < CELLS
      acc = mix_old(COLORS.unsafe_fetch(i), acc, 0.5)
      SINK.unsafe_put(i, acc)
      i += 1
    end
  end
  x.report("mix NEW (integer) x#{CELLS}/pass") do
    i = 0
    acc = 0x7f7f7f
    while i < CELLS
      acc = mix_new(COLORS.unsafe_fetch(i), acc, 0.5)
      SINK.unsafe_put(i, acc)
      i += 1
    end
  end
end

puts "\n(sink guard: #{SINK.unsafe_fetch(CELLS - 1)})"
