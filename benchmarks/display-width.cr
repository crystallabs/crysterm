require "benchmark"
require "../src/crysterm"

# Micro-benchmark for `::Crysterm::Unicode.display_width` / `str_width`, the per-line
# width measurement used during wrapping/alignment under `full_unicode?`.
#
#   * ascii        — plain English text (the common case even in unicode apps);
#                    every grapheme is width 1, so the result is just its length.
#   * accents      — latin + accented (non-ASCII, mostly width-1 graphemes).
#   * cjk          — wide East-Asian content (width-2 graphemes).
#   * emoji        — ZWJ / flag / skin-tone clusters.
#
# Run:  crystal run --release benchmarks/display-width.cr

include Crysterm

ascii = "The quick brown fox jumps over the lazy dog. " * 4 # ~180 ASCII cols
accents = "café résumé naïve façade Zürich Köln " * 4
cjk = "日本語のテキストをここに置きます。" * 4
emoji = "👍🏽🎉🇯🇵👨‍👩‍👧‍👦abc " * 8

# Sanity print so before/after results can be diffed.
{ {"ascii", ascii}, {"accents", accents}, {"cjk", cjk}, {"emoji", emoji} }.each do |name, s|
  print "#{name}: display_width=#{::Crysterm::Unicode.display_width(s)}\n"
end

Benchmark.ips do |x|
  x.report("ascii") { ::Crysterm::Unicode.display_width ascii }
  x.report("accents") { ::Crysterm::Unicode.display_width accents }
  x.report("cjk") { ::Crysterm::Unicode.display_width cjk }
  x.report("emoji") { ::Crysterm::Unicode.display_width emoji }
end
