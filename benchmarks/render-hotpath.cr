require "benchmark"
require "../src/crysterm"

# Before/after benchmark for the render/draw hot-path optimizations on branch
# perf/cell-alloc-hotpath. Each case runs the PREVIOUS ("OLD") approach and the
# NEW one side by side, so the two are directly comparable in a single process.
#
# IMPORTANT — read the numbers correctly:
#   * The `ips` (CPU-time) figures are NOISE-DOMINATED on a typical dev box
#     (±30–60% run to run; a case can flip faster/slower between runs). Do not
#     read fine-grained speed deltas from them.
#   * The DETERMINISTIC metrics are the real result: bytes allocated per batch
#     (printed under each case) and, for #6, the scan-iteration count. These do
#     not vary run to run. The point of these changes is removing per-FRAME heap
#     garbage (GC pauses cause frame-time jitter in a TUI), so allocation is the
#     metric that matters.
#
# Run:  crystal run --release benchmarks/render-hotpath.cr

include Crysterm

WIDTH  = 200
attr = Crysterm::Screen::DEFAULT_ATTR
ROUNDS = 5000

# A typical text row: mostly single-codepoint ASCII cells.
row = Crysterm::Screen::Row.new
WIDTH.times { |i| row.push attr, ('a' + (i % 26)) }

# MB allocated while running `block` `n` times (deterministic).
def alloc_mb(n, &block)
  GC.collect
  before = GC.stats.total_bytes
  n.times { block.call }
  (GC.stats.total_bytes - before) / (1024.0 * 1024.0)
end

def section(title)
  puts "\n#{title}"
end

puts "=" * 72
puts "Crysterm render hot-path: before (OLD) vs after (NEW)  [#{WIDTH}-cell row]"
puts "=" * 72

# ---------------------------------------------------------------------------
# #1  Legacy render path no longer does `ch.to_s` per cell (widget_rendering).
#     OLD allocated a 1-char String for every cell of every frame; NEW uses the
#     Char directly.
section "#1  legacy per-cell char  (every cell, every frame)"
Benchmark.ips do |x|
  x.report("OLD  grapheme = ch.to_s") do
    WIDTH.times { |i| s = ('a' + (i % 26)).to_s; s }
  end
  x.report("NEW  use ch directly") do
    WIDTH.times { |i| c = ('a' + (i % 26)); c }
  end
end
puts "  alloc: OLD #{alloc_mb(ROUNDS) { WIDTH.times { |i| s = ('a' + (i % 26)).to_s; s } }.round(2)} MB" \
     "  vs  NEW #{alloc_mb(ROUNDS) { WIDTH.times { |i| ('a' + (i % 26)) } }.round(2)} MB  (#{ROUNDS} rows)"

# ---------------------------------------------------------------------------
# #2  Cell#width — once per non-continuation cell in the draw loop.
section "#2  Cell#width  (draw loop)"
Benchmark.ips do |x|
  x.report("OLD  Unicode.width(cell.grapheme)") { WIDTH.times { |i| ::Crysterm::Unicode.width row[i].grapheme } }
  x.report("NEW  cell.width") { WIDTH.times { |i| row[i].width } }
end
puts "  alloc: OLD #{alloc_mb(ROUNDS) { WIDTH.times { |i| ::Crysterm::Unicode.width row[i].grapheme } }.round(2)} MB" \
     "  vs  NEW #{alloc_mb(ROUNDS) { WIDTH.times { |i| row[i].width } }.round(2)} MB  (#{ROUNDS} rows)"

# ---------------------------------------------------------------------------
# #3  grapheme equality — full_unicode render diff guard (widget_rendering).
section "#3  grapheme equality  (full_unicode diff guard)"
target = "m"
Benchmark.ips do |x|
  x.report("OLD  cell.grapheme == target") { WIDTH.times { |i| row[i].grapheme == target } }
  x.report("NEW  cell.grapheme_eq?(target)") { WIDTH.times { |i| row[i].grapheme_eq? target } }
end
puts "  alloc: OLD #{alloc_mb(ROUNDS) { WIDTH.times { |i| row[i].grapheme == target } }.round(2)} MB" \
     "  vs  NEW #{alloc_mb(ROUNDS) { WIDTH.times { |i| row[i].grapheme_eq? target } }.round(2)} MB  (#{ROUNDS} rows)"

# ---------------------------------------------------------------------------
# #4  SGR color emission — per attribute change in the draw loop.
section "#4  sgr_color emission  (per attribute change)"
io = IO::Memory.new 4096
Benchmark.ips do |x|
  x.report("OLD  io << Colors.sgr_color(...)") { io.clear; WIDTH.times { io << Colors.sgr_color(0xff8800, true, 0x1000000) } }
  x.report("NEW  Colors.sgr_color_to(io, ...)") { io.clear; WIDTH.times { Colors.sgr_color_to(io, 0xff8800, true, 0x1000000) } }
end
puts "  alloc: OLD #{alloc_mb(ROUNDS) { io.clear; WIDTH.times { io << Colors.sgr_color(0xff8800, true, 0x1000000) } }.round(2)} MB" \
     "  vs  NEW #{alloc_mb(ROUNDS) { io.clear; WIDTH.times { Colors.sgr_color_to(io, 0xff8800, true, 0x1000000) } }.round(2)} MB  (#{ROUNDS} rows)"

# ---------------------------------------------------------------------------
# #6  BCE space-run look-ahead. OLD rescans (x..end) from EVERY leading space
#     (O(width^2) on a "spaces then content" line); NEW remembers the breaker
#     and skips the redundant rescans (O(width)). The deterministic metric is
#     the number of cell comparisons performed.
section "#6  BCE look-ahead  (\"spaces then content\" line)"
split = WIDTH // 2
bce_row = Crysterm::Screen::Row.new
WIDTH.times { |i| i < split ? bce_row.push(attr, ' ') : bce_row.push(attr, 'x') }
da = attr

old_bce = -> do
  count = 0
  WIDTH.times do |x|
    next unless bce_row[x].char == ' '
    (x...WIDTH).each do |xx|
      count += 1
      break if bce_row[xx] != {da, ' '}
    end
  end
  count
end
new_bce = -> do
  count = 0
  skip_until = -1
  WIDTH.times do |x|
    next unless bce_row[x].char == ' '
    next unless x > skip_until
    breaker = WIDTH
    (x...WIDTH).each do |xx|
      count += 1
      if bce_row[xx] != {da, ' '}
        breaker = xx
        break
      end
    end
    skip_until = breaker - 1 if breaker < WIDTH
  end
  count
end
Benchmark.ips do |x|
  x.report("OLD  rescan from every space") { old_bce.call }
  x.report("NEW  skip past known breaker") { new_bce.call }
end
puts "  cell comparisons: OLD #{old_bce.call}  vs  NEW #{new_bce.call}  (per line; deterministic)"

# ---------------------------------------------------------------------------
# #7/#8  SGR scan over a styled line — the render escape loop and _parse_attr.
#        OLD slices the remaining content per escape (`content[(ci-1)..]`) then
#        ^-matches; NEW matches the SGR regex anchored in place. Same matches,
#        no tail-substring allocation.
section "#7/#8  SGR scan over a styled line  (render loop + _parse_attr)"
sgr_at = Crysterm::Widget::SGR_REGEX_AT_BEGINNING
sgr = Crysterm::Widget::SGR_REGEX
styled = (0...20).map { |i| "\e[3#{i % 8}mword#{i}" }.join(" ") + "\e[0m"
Benchmark.ips do |x|
  x.report("OLD  slice tail + ^-anchored match") do
    styled.each_char_with_index { |ch, i| styled[i..].match(sgr_at) if ch == '\e' }
  end
  x.report("NEW  in-place ANCHORED match") do
    styled.each_char_with_index { |ch, i| sgr.match(styled, i, options: Regex::MatchOptions::ANCHORED) if ch == '\e' }
  end
end
puts "  alloc: OLD #{alloc_mb(ROUNDS) { styled.each_char_with_index { |ch, i| styled[i..].match(sgr_at) if ch == '\e' } }.round(2)} MB" \
     "  vs  NEW #{alloc_mb(ROUNDS) { styled.each_char_with_index { |ch, i| sgr.match(styled, i, options: Regex::MatchOptions::ANCHORED) if ch == '\e' } }.round(2)} MB  (#{ROUNDS} scans)"

puts
puts "Note: #8 also SKIPS _parse_attr entirely on frames where the style's base"
puts "attr is unchanged — that is a per-frame O(content) scan avoided outright,"
puts "not measured above (it is a cache hit, i.e. zero work)."
puts
