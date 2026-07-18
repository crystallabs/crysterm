require "benchmark"
require "../src/crysterm"

# Micro-benchmarks for `widget_content.cr` hot paths.
#
#   * cache_hit   — `process_content` on an unchanged single-line widget (the
#                   per-frame common case: cache-key check + `style_to_attr`).
#   * reparse     — `set_content` of changing plain text (full reparse: clean
#                   gsub + wrap + parse_attr + ci + pcontent).
#   * reparse_tag — same, with `{bold}`-tagged content (adds `_parse_tags`).
#   * wrap_multi  — `_wrap_content` of a multi-line, word-wrapped paragraph.
#   * parse_tags  — `_parse_tags` alone on a heavily-tagged line.
#
# Run:  crystal run --release benchmarks/widget-content.cr

include Crysterm

devnull = File.open("/dev/null", "w")
devin = File.open("/dev/null", "r")
screen = Window.new output: devnull, input: devin, width: 200, height: 60
screen.width = 200
screen.height = 60
screen.realloc

# Single-line plain widget (label-like).
plain = Widget::Box.new parent: screen, top: 0, left: 0, width: 40, height: 1,
  content: "Hello, world!"
plain.process_content # prime the cache

# Tagged widget.
tagged = Widget::Box.new parent: screen, top: 1, left: 0, width: 40, height: 1,
  content: "{bold}Bold{/bold} and {red-fg}red{/red-fg} text", parse_tags: true
tagged.process_content

# Multi-line paragraph for wrapping.
para = Widget::Box.new parent: screen, top: 2, left: 0, width: 40, height: 10,
  content: ("The quick brown fox jumps over the lazy dog. " * 6)
para.process_content

heavy_tags = ("{bold}a{/bold}{red-fg}b{/red-fg}{green-fg}c{/green-fg} " * 12)

i = 0
Benchmark.ips do |x|
  x.report("cache_hit (unchanged)") { plain.process_content }

  x.report("reparse plain") do
    i += 1
    plain.set_content("Hello, world! #{i & 7}")
  end

  x.report("reparse tagged") do
    i += 1
    tagged.set_content("{bold}Bold#{i & 7}{/bold} and {red-fg}red{/red-fg} text")
  end

  x.report("_wrap_content multi") { para._wrap_content(para.content, 38, into: para._clines) }

  x.report("_parse_tags heavy") { tagged._parse_tags(heavy_tags) }
end
