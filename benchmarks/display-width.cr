require "benchmark"
require "../src/crysterm"

# Micro-benchmark for `::Crysterm::Unicode.display_width` / `str_width`, the
# per-line width measurement used during wrapping/alignment under `full_unicode?`.
#
#   * ascii        — plain English text; every grapheme is width 1.
#   * accents      — latin + accented (non-ASCII, mostly width-1 graphemes).
#   * cjk          — wide East-Asian content (width-2 graphemes).
#   * emoji        — ZWJ / flag / skin-tone clusters.
#
# The `sgr-*` cases measure `Unicode.str_width` on lines carrying inline SGR
# runs (styled content, measured per line while wrapping): `sgr-ascii` is
# printable ASCII between the runs, `sgr-cjk` wide text, `sgr-legacy` the
# codepoint-count metric (`full_unicode: false`).
#
# Run:  crystal run --release benchmarks/display-width.cr

include Crysterm

ascii = "The quick brown fox jumps over the lazy dog. " * 4 # ~180 ASCII cols
accents = "café résumé naïve façade Zürich Köln " * 4
cjk = "日本語のテキストをここに置きます。" * 4
emoji = "👍🏽🎉🇯🇵👨‍👩‍👧‍👦abc " * 8

sgr_ascii = "\e[1;31mThe quick\e[0m brown \e[38;2;10;20;30mfox jumps\e[m over the lazy dog. " * 4
sgr_cjk = "\e[1m日本語の\e[0mテキストを\e[32mここに\e[m置きます。" * 4

# Sanity print for before/after diffing.
{ {"ascii", ascii}, {"accents", accents}, {"cjk", cjk}, {"emoji", emoji} }.each do |name, s|
  print "#{name}: display_width=#{::Crysterm::Unicode.display_width(s)}\n"
end
{ {"sgr-ascii", sgr_ascii}, {"sgr-cjk", sgr_cjk} }.each do |name, s|
  print "#{name}: str_width=#{::Crysterm::Unicode.str_width(s, true)} legacy=#{::Crysterm::Unicode.str_width(s, false)}\n"
end

Benchmark.ips do |x|
  x.report("ascii") { ::Crysterm::Unicode.display_width ascii }
  x.report("accents") { ::Crysterm::Unicode.display_width accents }
  x.report("cjk") { ::Crysterm::Unicode.display_width cjk }
  x.report("emoji") { ::Crysterm::Unicode.display_width emoji }
  x.report("sgr-ascii") { ::Crysterm::Unicode.str_width sgr_ascii, true }
  x.report("sgr-cjk") { ::Crysterm::Unicode.str_width sgr_cjk, true }
  x.report("sgr-legacy") { ::Crysterm::Unicode.str_width sgr_cjk, false }
end
