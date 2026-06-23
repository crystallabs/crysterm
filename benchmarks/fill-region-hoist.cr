require "benchmark"
require "../src/crysterm"

# Validates the array-hoist on `Screen#fill_region` — the per-frame full-screen
# clear path (`clear_region` in `_render` runs it over the whole grid every
# frame). OLD walked the region through `each_region_cell`, constructing a `Cell`
# handle and a bounds-checked `line[x]?` per cell; NEW indexes the row's hoisted
# `attrs`/`chars` arrays with `unsafe_fetch`/`unsafe_put`.
#
# Run:  crystal run --release benchmarks/fill-region-hoist.cr

include Crysterm

WIDTH  = 200
HEIGHT =  50
attr = Crysterm::Screen::DEFAULT_ATTR
ch = ' '

# Build a HEIGHT-row grid of plain ASCII cells (no grapheme overlays — the
# common case), mirroring what `@lines` holds.
def make_grid
  rows = Array(Crysterm::Screen::Row).new
  HEIGHT.times do
    row = Crysterm::Screen::Row.new
    WIDTH.times { |i| row.push Crysterm::Screen::DEFAULT_ATTR, ('a' + (i % 26)) }
    rows << row
  end
  rows
end

# OLD: the previous each_region_cell + Cell-handle implementation, inlined here
# so both run in one process.
def fill_old(lines, attr, ch, override = false)
  0.upto(HEIGHT - 1) do |y|
    line = lines[y]
    0.upto(WIDTH - 1) do |x|
      cell = line[x]
      if override || cell != {attr, ch}
        cell.attr = attr
        cell.char = ch
        line.dirty = true
      end
    end
  end
end

# NEW: hoisted backing arrays + unsafe access.
def fill_new(lines, attr, ch, override = false)
  0.upto(HEIGHT - 1) do |y|
    line = lines[y]
    attrs = line.attrs
    chars = line.chars
    n = attrs.size
    x = 0
    while x < n
      if override || attrs.unsafe_fetch(x) != attr || chars.unsafe_fetch(x) != ch || !line.grapheme_at?(x).nil?
        attrs.unsafe_put(x, attr)
        chars.unsafe_put(x, ch)
        line.delete_grapheme(x)
        line.dirty = true
      end
      x += 1
    end
  end
end

grid_old = make_grid
grid_new = make_grid

puts "=" * 72
puts "fill_region full-screen clear: OLD (Cell handles) vs NEW (array hoist)"
puts "grid #{WIDTH}x#{HEIGHT}, content cells -> default (worst case: every cell changes)"
puts "=" * 72

# Correctness: after a clear the grids must be identical, all default/space.
fill_old grid_old, attr, ch
fill_new grid_new, attr, ch
ok = HEIGHT.times.all? do |y|
  WIDTH.times.all? { |x| grid_old[y][x] == grid_new[y][x] && grid_new[y][x] == {attr, ch} }
end
puts "correctness (OLD == NEW, all cleared to default): #{ok ? "OK" : "MISMATCH"}"

# Steady-state case: grid is ALREADY clear, so neither writes (the per-frame
# common case once the background is stable — pure comparison cost).
puts "\n--- already-clear grid (no writes; pure scan cost) ---"
Benchmark.ips do |x|
  x.report("OLD  Cell handle per cell") { fill_old grid_old, attr, ch }
  x.report("NEW  hoisted arrays") { fill_new grid_new, attr, ch }
end

# Worst case: re-dirty the grid each batch so every cell triggers a write.
puts "\n--- dirty grid (every cell rewritten) ---"
Benchmark.ips do |bm|
  bm.report("OLD  Cell handle per cell") do
    HEIGHT.times { |y| WIDTH.times { |i| grid_old[y].chars.unsafe_put(i, ('a' + (i % 26))) } }
    fill_old grid_old, attr, ch
  end
  bm.report("NEW  hoisted arrays") do
    HEIGHT.times { |y| WIDTH.times { |i| grid_new[y].chars.unsafe_put(i, ('a' + (i % 26))) } }
    fill_new grid_new, attr, ch
  end
end
