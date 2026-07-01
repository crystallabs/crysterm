require "benchmark"
require "../lib/term_colors/src/term_colors"

# `TermColors#match` (reached from `Colors.sgr_color_to` on non-TrueColor
# terminals) scans all 256 `HI2RGB` entries per cache miss, computing
# `color_distance` (using `**2`) each step, and probes `CACHE_MATCH` twice on
# a hit (`has_key?` then `[]`). Checks:
#  (a) `x ** 2` vs `x * x` in the distance inner loop, and
#  (b) the cache-hit path (double vs single probe).
#
# Run:  crystal run --release benchmarks/term-colors-match.cr

include TermColors

def dist_pow(r1, g1, b1, r2, g2, b2)
  ((30 * (r1 - r2))**2) + ((59 * (g1 - g2))**2) + ((11 * (b1 - b2))**2)
end

def dist_mul(r1, g1, b1, r2, g2, b2)
  dr = 30 * (r1 - r2); dg = 59 * (g1 - g2); db = 11 * (b1 - b2)
  (dr * dr) + (dg * dg) + (db * db)
end

Benchmark.ips do |x|
  x.report("color_distance  **2") { dist_pow(12, 34, 56, 200, 100, 50) }
  x.report("color_distance  x*x") { dist_mul(12, 34, 56, 200, 100, 50) }
end

# Cache-hit path: warm the cache, then repeatedly hit one key.
match 12, 34, 56
h = (12 << 16) | (34 << 8) | 56
Benchmark.ips do |x|
  x.report("CACHE_MATCH double probe") do
    TermColors::CACHE_MATCH.has_key?(h) ? TermColors::CACHE_MATCH[h] : -1
  end
  x.report("CACHE_MATCH fetch (single)") do
    TermColors::CACHE_MATCH.fetch(h) { -1 }
  end
end
