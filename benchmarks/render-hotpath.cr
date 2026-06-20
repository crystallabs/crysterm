require "benchmark"
require "../src/crysterm"

# Quantifies the per-cell allocation removals on the render/draw hot path
# (branch perf/cell-alloc-hotpath). Each case compares the PREVIOUS approach
# (still callable) against the NEW one and reports both throughput (ips) and
# bytes allocated per fixed batch (the real point — these were per-cell garbage
# on every frame).
#
# Run:  crystal run --release benchmarks/render-hotpath.cr

include Crysterm

WIDTH = 200
attr  = Crysterm::Screen::DEFAULT_ATTR

# A typical text row: mostly single-codepoint ASCII cells.
row = Crysterm::Screen::Row.new
WIDTH.times { |i| row.push attr, ('a' + (i % 26)) }

# Reports MB allocated while running `block` `n` times.
def alloc_mb(n, &block)
  GC.collect
  before = GC.stats.total_bytes
  n.times { block.call }
  (GC.stats.total_bytes - before) / (1024.0 * 1024.0)
end

puts "=" * 72
puts "Crysterm render hot-path benchmark (#{WIDTH}-cell row)"
puts "=" * 72

# ---------------------------------------------------------------------------
puts "\n#2  Cell#width  (draw loop: once per non-continuation cell)\n"
Benchmark.ips do |x|
  x.report("OLD  Unicode.width(cell.grapheme)") do
    WIDTH.times { |i| ::Crysterm::Unicode.width row[i].grapheme }
  end
  x.report("NEW  cell.width") do
    WIDTH.times { |i| row[i].width }
  end
end
rounds = 5000
puts "  alloc: OLD #{alloc_mb(rounds) { WIDTH.times { |i| ::Crysterm::Unicode.width row[i].grapheme } }.round(2)} MB" \
     "  vs  NEW #{alloc_mb(rounds) { WIDTH.times { |i| row[i].width } }.round(2)} MB" \
     "  (#{rounds} rows)"

# ---------------------------------------------------------------------------
puts "\n#3  grapheme equality  (full_unicode render diff guard)\n"
target = "m"
Benchmark.ips do |x|
  x.report("OLD  cell.grapheme == target") do
    WIDTH.times { |i| row[i].grapheme == target }
  end
  x.report("NEW  cell.grapheme_eq?(target)") do
    WIDTH.times { |i| row[i].grapheme_eq? target }
  end
end
puts "  alloc: OLD #{alloc_mb(rounds) { WIDTH.times { |i| row[i].grapheme == target } }.round(2)} MB" \
     "  vs  NEW #{alloc_mb(rounds) { WIDTH.times { |i| row[i].grapheme_eq? target } }.round(2)} MB" \
     "  (#{rounds} rows)"

# ---------------------------------------------------------------------------
puts "\n#4  sgr_color emission  (per attribute change in draw)\n"
io = IO::Memory.new 4096
Benchmark.ips do |x|
  x.report("OLD  io << Colors.sgr_color(...)") do
    io.clear
    WIDTH.times { io << Colors.sgr_color(0xff8800, true, 0x1000000) }
  end
  x.report("NEW  Colors.sgr_color_to(io, ...)") do
    io.clear
    WIDTH.times { Colors.sgr_color_to(io, 0xff8800, true, 0x1000000) }
  end
end
puts "  alloc: OLD #{alloc_mb(rounds) { io.clear; WIDTH.times { io << Colors.sgr_color(0xff8800, true, 0x1000000) } }.round(2)} MB" \
     "  vs  NEW #{alloc_mb(rounds) { io.clear; WIDTH.times { Colors.sgr_color_to(io, 0xff8800, true, 0x1000000) } }.round(2)} MB" \
     "  (#{rounds} rows)"

puts
