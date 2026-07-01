require "benchmark"
require "../src/crysterm"

# Micro-benchmark for `wrap_cut_index` on non-ASCII content, where
# `String#[](Int)` is O(index) and the original char-by-char scan was O(n^2).
# Exercises both `full_unicode?` paths.
#
# Run:  crystal run --release benchmarks/wrap-cut-multibyte.cr

include Crysterm

devnull = File.open("/dev/null", "w")
devin = File.open("/dev/null", "r")
screen = Screen.new output: devnull, input: devin, width: 200, height: 60,
  force_unicode: true, full_unicode: true
screen.width = 200
screen.height = 60
screen.realloc

w = Widget::Box.new parent: screen, top: 0, left: 0, width: 80, height: 1

# Long multibyte lines (no SGR), plain multibyte, and SGR-laden multibyte.
cjk = "日本語のテキストをここに置きます。" * 12                         # ~204 wide CJK cps
accents = "café résumé naïve façade Zürich Köln " * 12 # latin + combining
emoji = "👍🏽🎉🇯🇵👨‍👩‍👧‍👦abc " * 30                        # graphemes/ZWJ/flags
sgr_multi = ("\e[31m日本\e[0m語のテ\e[1mキスト\e[0m " * 20)

lines = {cjk, accents, emoji, sgr_multi}

# Print cut indices so before/after can be diffed.
{true, false}.each do |full|
  screen.full_unicode = full
  lines.each_with_index do |l, idx|
    print "full=#{full} line=#{idx} cut(40)=#{w.wrap_cut_index(l, 40)} cut(120)=#{w.wrap_cut_index(l, 120)}\n"
  end
end

Benchmark.ips do |x|
  {true, false}.each do |full|
    screen.full_unicode = full
    lines.each_with_index do |l, idx|
      x.report("full=#{full} l#{idx} cut40") { w.wrap_cut_index(l, 40) }
      x.report("full=#{full} l#{idx} cut120") { w.wrap_cut_index(l, 120) }
    end
  end
end
