require "benchmark"
require "../src/crysterm"

# Micro-benchmark for the per-cell diff compare in `Screen#draw`
# (`screen_drawing.cr`). Compares the OLD path against the NEW one:
#
#   OLD  desired_attr = line[x].attr      # Indexable#[] : bounds check + Cell
#        desired_char = line[x].char      # again
#        ox == {desired_attr, desired_char}   # Cell#==(Tuple): incl. grapheme_overlay
#
#   NEW  l_attrs/l_chars/o_attrs/o_chars hoisted once per row
#        desired_attr = l_attrs.unsafe_fetch(x)
#        desired_char = l_chars.unsafe_fetch(x)
#        o_attrs.unsafe_fetch(x) == desired_attr && o_chars.unsafe_fetch(x) == desired_char
#        (grapheme_overlay check skipped entirely when !full_unicode)
#
# This change saves NO allocations (the primitive Tuple never escaped to the
# heap), so the only metric is CPU time — which the render-hotpath bench warns
# is noisy. Run it a few times and look for a CONSISTENT direction, not a
# precise factor.
#
# Run:  crystal run --release benchmarks/cell-diff-compare.cr

include Crysterm

WIDTH  =  200
ROUNDS = 5000
attr = Crysterm::Screen::DEFAULT_ATTR

# Build two equal rows: the common hot case where every cell is unchanged, so
# the diff guard fires on every cell (the path we sped up).
line = Crysterm::Screen::Row.new
o = Crysterm::Screen::Row.new
WIDTH.times do |i|
  ch = 'a' + (i % 26)
  line.push attr, ch
  o.push attr, ch
end

# A half-changed row, to also exercise the not-equal branch.
o_half = Crysterm::Screen::Row.new
WIDTH.times { |i| o_half.push attr, (i < WIDTH // 2 ? ('a' + (i % 26)) : 'Z') }

# OLD per-cell read + compare, faithful to the pre-change draw loop.
def old_diff(line, o)
  cnt = 0
  WIDTH.times do |x|
    desired_attr = line[x].attr
    desired_char = line[x].char
    if ox = o[x]?
      cnt += 1 if ox == {desired_attr, desired_char}
    end
  end
  cnt
end

# NEW per-cell read + compare (legacy mode: full_unicode off → overlay skipped).
def new_diff(line, o)
  cnt = 0
  l_attrs = line.attrs
  l_chars = line.chars
  o_attrs = o.attrs
  o_chars = o.chars
  WIDTH.times do |x|
    desired_attr = l_attrs.unsafe_fetch(x)
    desired_char = l_chars.unsafe_fetch(x)
    if x < o.size
      unchanged = o_attrs.unsafe_fetch(x) == desired_attr && o_chars.unsafe_fetch(x) == desired_char
      cnt += 1 if unchanged
    end
  end
  cnt
end

# Sanity: both produce identical verdicts.
raise "mismatch (equal)" unless old_diff(line, o) == new_diff(line, o)
raise "mismatch (half)" unless old_diff(line, o_half) == new_diff(line, o_half)

puts "=" * 72
puts "Cell diff compare: OLD vs NEW  [#{WIDTH}-cell row]"
puts "unchanged cells/row — equal: #{new_diff(line, o)}, half: #{new_diff(line, o_half)}"
puts "=" * 72

puts "\n#1  all cells unchanged  (the hot common case)"
Benchmark.ips do |x|
  x.report("OLD  line[x] + ox == {..}") { old_diff(line, o) }
  x.report("NEW  hoisted + inlined") { new_diff(line, o) }
end
puts "  alloc: OLD #{alloc_mb(ROUNDS) { old_diff(line, o) }.round(2)} MB" \
     "  vs  NEW #{alloc_mb(ROUNDS) { new_diff(line, o) }.round(2)} MB  (#{ROUNDS} rows)"

puts "\n#2  half the cells changed"
Benchmark.ips do |x|
  x.report("OLD  line[x] + ox == {..}") { old_diff(line, o_half) }
  x.report("NEW  hoisted + inlined") { new_diff(line, o_half) }
end
puts "  alloc: OLD #{alloc_mb(ROUNDS) { old_diff(line, o_half) }.round(2)} MB" \
     "  vs  NEW #{alloc_mb(ROUNDS) { new_diff(line, o_half) }.round(2)} MB  (#{ROUNDS} rows)"

# MB allocated while running `block` `n` times (deterministic).
def alloc_mb(n, &block)
  GC.collect
  before = GC.stats.total_bytes
  n.times { block.call }
  (GC.stats.total_bytes - before) / (1024.0 * 1024.0)
end
