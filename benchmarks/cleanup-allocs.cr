require "../src/crysterm"

# Deterministic allocation check for the buffer/cache cleanups:
#   * divert() reuses @tmpbuf instead of allocating a throwaway IO::Memory per
#     line insert/delete op.
#   * screenshot() reuses one IO::Memory across rows instead of a String::Builder
#     per row.
#   * Table#calculate_maxes caches @maxes, so a render with unchanged data no
#     longer re-scans every cell.
#
# Per the repo's benchmark philosophy, the meaningful metric is bytes allocated
# (deterministic), not ips (noise-dominated). OLD vs NEW are reconstructed inline
# for the first two; the table case exercises the real method both ways.
#
# Run:  crystal run --release benchmarks/cleanup-allocs.cr

include Crysterm

def alloc_mb(n, &block)
  GC.collect
  before = GC.stats.total_bytes
  n.times { block.call }
  (GC.stats.total_bytes - before) / (1024.0 * 1024.0)
end

ROUNDS = 20_000
CSR    = "\e[1;24r\e[5;1H\e[2L\e[1;24r" # representative line-op escape burst

puts "=" * 60
puts "Cleanup allocations: OLD vs NEW  (#{ROUNDS} rounds)"
puts "=" * 60

# 1. divert temp buffer ------------------------------------------------------
shared = IO::Memory.new
old_divert = alloc_mb(ROUNDS) do
  buf = IO::Memory.new # the throwaway the 4 call sites used to allocate
  buf << CSR
  buf.to_slice
end
new_divert = alloc_mb(ROUNDS) do
  shared.clear # reused @tmpbuf
  shared << CSR
  shared.to_slice
end
puts "\n#1 divert line-op buffer"
puts "   OLD #{old_divert.round(3)} MB   NEW #{new_divert.round(3)} MB"

# 2. screenshot per-row buffer ----------------------------------------------
height = 24
width = 80
reuse = IO::Memory.new
old_ss = alloc_mb(ROUNDS) do
  height.times do
    ob = String::Builder.new
    width.times { |i| ob << ('a' + (i % 26)) }
    ob.to_s
  end
end
new_ss = alloc_mb(ROUNDS) do
  height.times do
    reuse.clear
    width.times { |i| reuse << ('a' + (i % 26)) }
    reuse.to_slice
  end
end
puts "\n#2 screenshot per-row buffer (#{height}x#{width})"
puts "   OLD #{old_ss.round(3)} MB   NEW #{new_ss.round(3)} MB"

# 3. table calculate_maxes: cache hit vs forced recompute -------------------
s = Crysterm::Screen.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
rows = Array.new(20) { |r| Array.new(6) { |c| "cell-#{r}-#{c}" } }
t = Crysterm::Widget::Table.new parent: s, rows: rows

recompute = alloc_mb(ROUNDS) do
  t.invalidate_maxes # what set_data/resize does
  t.calculate_maxes  # full re-scan of every cell
end
cache_hit = alloc_mb(ROUNDS) do
  t.calculate_maxes # unchanged data: cache hit, no work
end
puts "\n#3 Table#calculate_maxes per render (20x6 cells)"
puts "   recompute #{recompute.round(3)} MB   cache-hit #{cache_hit.round(3)} MB"
puts "   (cache-hit is what every render-with-unchanged-data now costs)"
