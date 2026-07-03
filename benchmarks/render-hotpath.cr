require "benchmark"
require "../src/crysterm"

# Before/after benchmark for the render/draw hot-path optimizations on branch
# perf/cell-alloc-hotpath. Each case runs the PREVIOUS ("OLD") approach and the
# NEW one side by side for direct comparison in a single process.
#
# IMPORTANT — read the numbers correctly:
#   * The `ips` (CPU-time) figures are NOISE-DOMINATED on a typical dev box
#     (±30-60% run to run). Don't read fine-grained speed deltas from them.
#   * The DETERMINISTIC metrics are the real result: bytes allocated per batch
#     and, for #6, the scan-iteration count. These don't vary run to run. The
#     point is removing per-frame heap garbage (GC pauses cause frame-time
#     jitter in a TUI), so allocation is the metric that matters.
#
# Run:  crystal run --release benchmarks/render-hotpath.cr

include Crysterm

WIDTH  = 200
attr = Crysterm::Window::DEFAULT_ATTR
ROUNDS = 5000

# A typical text row: mostly single-codepoint ASCII cells.
row = Crysterm::Window::Row.new
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
# #6  BCE space-run look-ahead. OLD rescans (x..end) from every leading space
#     (O(width^2) on a "spaces then content" line); NEW remembers the breaker
#     and skips redundant rescans (O(width)). Metric: cell comparisons performed.
section "#6  BCE look-ahead  (\"spaces then content\" line)"
split = WIDTH // 2
bce_row = Crysterm::Window::Row.new
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
#        OLD slices the remaining content per escape then ^-matches; NEW
#        matches the SGR regex anchored in place. Same matches, no
#        tail-substring allocation.
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

# ---------------------------------------------------------------------------
# #10  StringIndex reuse — `_render` builds a codepoint index over @_pcontent
#      once per widget every frame. OLD rebuilt it each frame; for non-ASCII
#      that re-materializes a `chars` array (per-frame garbage), and even ASCII
#      re-runs the O(n) `ascii_only?` scan. NEW reuses a cached index while
#      @_pcontent is unchanged (the common case: content changes on edit only).
section "#10  StringIndex reuse  (per widget, every frame)"
ascii_line = (0...WIDTH).map { |i| ('a' + (i % 26)) }.join
unicode_line = (0...WIDTH).map { |i| (i % 3 == 0) ? 'é' : ('a' + (i % 26)) }.join
cached_ascii = Crysterm::StringIndex.new ascii_line
cached_unicode = Crysterm::StringIndex.new unicode_line
Benchmark.ips do |x|
  x.report("OLD  rebuild each frame (unicode)") { Crysterm::StringIndex.new unicode_line }
  x.report("NEW  reuse cached      (unicode)") { cached_unicode.built_from?(unicode_line) ? cached_unicode : Crysterm::StringIndex.new(unicode_line) }
end
puts "  alloc unicode: OLD #{alloc_mb(ROUNDS) { Crysterm::StringIndex.new unicode_line }.round(2)} MB" \
     "  vs  NEW #{alloc_mb(ROUNDS) { cached_unicode.built_from?(unicode_line) ? cached_unicode : Crysterm::StringIndex.new(unicode_line) }.round(2)} MB  (#{ROUNDS} frames)"
puts "  alloc ascii:   OLD #{alloc_mb(ROUNDS) { Crysterm::StringIndex.new ascii_line }.round(2)} MB" \
     "  vs  NEW #{alloc_mb(ROUNDS) { cached_ascii.built_from?(ascii_line) ? cached_ascii : Crysterm::StringIndex.new(ascii_line) }.round(2)} MB  (#{ROUNDS} frames)  [ASCII already 0-alloc; NEW also skips the per-frame ascii_only? rescan]"

puts
puts "Note: #8 also SKIPS _parse_attr entirely on frames where the style's base"
puts "attr is unchanged — that is a per-frame O(content) scan avoided outright,"
puts "not measured above (it is a cache hit, i.e. zero work)."

# ---------------------------------------------------------------------------
# #9  attr2code — converts an SGR sequence to a packed attr, per SGR every
#     frame for colored content. OLD did `code[2...-1].split(';')` (substring +
#     Array(String)); NEW parses the bytes in place.
section "#9  attr2code  (per SGR sequence, every frame)"
dfl = Crysterm::Window::DEFAULT_ATTR
codes = ["\e[0m", "\e[1m", "\e[31m", "\e[1;31m", "\e[38;5;208m", "\e[38;2;255;136;0m", "\e[39;49m"]
Benchmark.ips do |x|
  # OLD allocation source: the split that NEW removes (rest of attr2code is
  # int/Attr math that allocates nothing in either version).
  x.report("OLD  code[2...-1].split(';')") { codes.each { |c| c[2...-1].split(';') } }
  x.report("NEW  Screen.attr2code (full)") { codes.each { |c| Crysterm::Screen.attr2code(c, dfl, dfl) } }
end
puts "  alloc: OLD #{alloc_mb(ROUNDS) { codes.each { |c| c[2...-1].split(';') } }.round(2)} MB" \
     "  vs  NEW #{alloc_mb(ROUNDS) { codes.each { |c| Crysterm::Screen.attr2code(c, dfl, dfl) } }.round(2)} MB" \
     "  (#{ROUNDS} x #{codes.size} codes)  [NEW does the FULL conversion]"

# ---------------------------------------------------------------------------
# #2(layout)  percentage position/size resolution — per aleft/atop/awidth/
#     aheight call (several per widget per frame) for string-positioned widgets.
section "#layout  percentage position parsing  (per position call)"
exprs = ["50%", "50%", "50%+5", "100%-1", "33%"]
Benchmark.ips do |x|
  x.report("OLD  split(/(?=\\+|-)/) formula") do
    exprs.each do |e|
      p = e.split(/(?=\+|-)/); b = p[0][0...-1].to_f / 100; v = (80 * b).to_i; v += p[1].to_i if p[1]?; v
    end
  end
  x.report("NEW  Widget.dimension") { exprs.each { |e| Widget.dimension(e, 80) } }
end
puts "  alloc: OLD #{alloc_mb(ROUNDS) { exprs.each { |e| p = e.split(/(?=\+|-)/); b = p[0][0...-1].to_f / 100; v = (80 * b).to_i; v += p[1].to_i if p[1]?; v } }.round(2)} MB" \
     "  vs  NEW #{alloc_mb(ROUNDS) { exprs.each { |e| Widget.dimension(e, 80) } }.round(2)} MB  (#{ROUNDS} x #{exprs.size} exprs)"

# ---------------------------------------------------------------------------
# #docking  per-frame dock-stop iteration (only when dock_borders is on).
section "#docking  stop-row iteration  (per frame with dock_borders)"
stops = {} of Int32 => Bool
(0...30).each { |i| stops[i * 2] = true }
Benchmark.ips do |x|
  x.report("OLD  keys.map(&.to_i).sort!") { stops.keys.map(&.to_i).sort! }
  x.report("NEW  keys.sort!") { stops.keys.sort! }
end
puts "  alloc: OLD #{alloc_mb(ROUNDS) { stops.keys.map(&.to_i).sort! }.round(2)} MB" \
     "  vs  NEW #{alloc_mb(ROUNDS) { stops.keys.sort! }.round(2)} MB  (#{ROUNDS} frames)"

# ---------------------------------------------------------------------------
# #11  code2attr — SGR emission on the draw BCE line-clear (per cleared line,
#      every frame). OLD built and returned a fresh `String`; NEW writes the
#      same sequence straight into the line buffer (`Screen.code2attr_to`), so
#      clearing N lines no longer produces N throwaway strings.
section "#11  code2attr  (BCE line-clear, per cleared line)"
attr_code = Crysterm::Attr.pack(Crysterm::Attr::BOLD, Crysterm::Attr.pack_color(0xff8800), Crysterm::Attr.pack_color(0x102030))
cio = IO::Memory.new 64
old_code2attr = -> do
  String.build do |o|
    o << "\e["
    o << "1;38;2;255;136;0;48;2;16;32;48"
    o.back 1
    o << 'm'
  end
end
Benchmark.ips do |x|
  x.report("OLD  String.build code2attr") { old_code2attr.call }
  x.report("NEW  code2attr_to(io, ...)") { cio.clear; Crysterm::Screen.code2attr_to(cio, attr_code, 0x1000000) }
end
puts "  alloc: OLD #{alloc_mb(ROUNDS) { old_code2attr.call }.round(2)} MB" \
     "  vs  NEW #{alloc_mb(ROUNDS) { cio.clear; Crysterm::Screen.code2attr_to(cio, attr_code, 0x1000000) }.round(2)} MB  (#{ROUNDS} cleared lines)"

# ---------------------------------------------------------------------------
# #convert  Colors.convert(String) — color-string parsing in `sattr`, run per
#      widget every frame. OLD reparsed the string each call; NEW memoizes the
#      parse (the app's set of color strings is small and bounded), so
#      steady-state frames are allocation-free.
section "#convert  Colors.convert(String)  (per sattr, per widget, every frame)"
Colors.convert_cached("red"); Colors.convert_cached("#ff8800") # warm the cache
Benchmark.ips do |x|
  x.report("OLD  Colors.convert(str)") { Colors.convert("red"); Colors.convert("#ff8800") }
  x.report("NEW  Colors.convert_cached") { Colors.convert_cached("red"); Colors.convert_cached("#ff8800") }
end
puts "  alloc: OLD #{alloc_mb(ROUNDS) { Colors.convert("red"); Colors.convert("#ff8800") }.round(2)} MB" \
     "  vs  NEW #{alloc_mb(ROUNDS) { Colors.convert_cached("red"); Colors.convert_cached("#ff8800") }.round(2)} MB  (#{ROUNDS} x 2 colors)"

puts
