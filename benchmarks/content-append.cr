require "benchmark"
require "../src/crysterm"

# Appending text to a text widget (the prime case: `Log#add` / `push_line`).
#
# BEFORE this optimization, every appended line went:
#   push_line -> insert_line -> rebuild_content_from_fake
#             -> set_content(@_clines.fake.join("\n")) -> process_content
# i.e. a full re-join + full reparse of ALL content per line: whole-string
# `matches? TAG_REGEX`, control-char `gsub`, `_parse_tags`, `_wrap_content`,
# `_parse_attr`, `@_pcontent = join`. That is O(total) per append, O(n^2) total.
#
# AFTER, `push_line` first tries `append_content`, which cleans / tag-parses /
# wraps / attr-scans ONLY the new segment and splices it onto the tail of
# `@_clines` — O(appended). It falls back to the old path when it cannot
# guarantee an identical result (stale cache, width change, open tag at the
# boundary).
#
# Here "before" = calling `insert_line` at the end index directly (the old slow
# path), "after" = the real `push_line`. The correctness block proves the fast
# build-up is byte-identical to a single one-shot `set_content`.
#
# Run:  crystal run --release benchmarks/content-append.cr

include Crysterm

def make_box(parse_tags = false, width = 80)
  screen = Crysterm::Screen.new
  screen.width = 120
  screen.height = 40
  box = Crysterm::Widget::Box.new(width: width, height: 20)
  box.parse_tags = parse_tags
  screen.append box
  box
end

def plain_line(i)
  "log line number #{i} with a moderate amount of content here"
end

def tagged_line(i)
  "{green-fg}[INFO]{/green-fg} log line number #{i} with {bold}content{/bold} here"
end

# Old slow path's PARSE cost: splice the new line into `fake` and reparse the
# whole content (exactly what `insert_line` -> `rebuild_content_from_fake` did).
# We call `set_content` directly rather than `insert_line` to skip the terminal
# line-scroll optimization, which needs a real rendered screen (it crashes
# headless) and is render bookkeeping, not the content-parse cost being compared.
def slow_push(box, line)
  box._clines.fake << line
  box.set_content(box._clines.fake.join("\n"), true)
end

# --------------------------------------------------------------------------
# Correctness: building content line-by-line with `push_line` (which uses the
# fast `append_content`) must be byte-identical, in every `CLines` field, to a
# single one-shot `set_content` of the same lines.
# --------------------------------------------------------------------------
def assert_equiv(name, tags, lines)
  inc = make_box(tags)
  lines.each { |l| inc.push_line l }
  one = make_box(tags)
  one.set_content lines.join("\n")

  ic = inc._clines
  oc = one._clines
  checks = {
    "pcontent" => inc._pcontent == one._pcontent,
    "lines"    => ic.lines == oc.lines,
    "fake"     => ic.fake == oc.fake,
    "ci"       => ic.ci == oc.ci,
    "rtof"     => ic.rtof == oc.rtof,
    "ftor"     => ic.ftor == oc.ftor,
    "attr"     => ic.attr == oc.attr,
    "maxwidth" => ic.max_width == oc.max_width,
  }
  bad = checks.reject { |_, v| v }.keys
  printf "  %-46s => %s%s\n", name, bad.empty? ? "OK" : "MISMATCH", bad.empty? ? "" : " (#{bad.join(", ")})"
end

puts "== Correctness checks (push_line build-up == one-shot set_content) =="
long = "this is a deliberately long line designed to exceed the eighty column wrap width and be split into several wrapped rows"
assert_equiv "plain lines", false, (0...300).map { |i| plain_line(i) }
assert_equiv "tagged lines", true, (0...300).map { |i| tagged_line(i) }
assert_equiv "long wrapped lines (multi-real-per-fake)", false, Array.new(40) { |i| "#{i} #{long}" }
assert_equiv "tagged + wrapped", true, Array.new(40) { |i| "{green-fg}[#{i}]{/green-fg} #{long}" }
assert_equiv "multi-line text per push", false, Array.new(40) { |i| "line #{i}a\nline #{i}b\nline #{i}c" }
assert_equiv "unclosed colour carries across lines", true, ["{red-fg}opens red", "still red", "still red 2"]
assert_equiv "blank lines interspersed", false, ["a", "", "b", "", "", "c"]
puts

# --------------------------------------------------------------------------
# Build-up cost: total time to append N lines.
# --------------------------------------------------------------------------
puts "== Total time to append N lines =="
{false, true}.each do |tags|
  gen = tags ? ->tagged_line(Int32) : ->plain_line(Int32)
  puts tags ? "-- parse_tags = true (tagged lines) --" : "-- parse_tags = false (plain lines) --"
  printf "  %-6s  %12s  %12s  %8s\n", "N", "before (ms)", "after (ms)", "speedup"
  {250, 500, 1000, 2000, 4000}.each do |n|
    b = make_box(tags)
    before = Benchmark.measure { n.times { |i| slow_push(b, gen.call(i)) } }.real

    a = make_box(tags)
    after = Benchmark.measure { n.times { |i| a.push_line gen.call(i) } }.real

    printf "  %-6d  %12.2f  %12.2f  %7.1fx\n", n, before * 1000, after * 1000, before / after
  end
  puts
end

# --------------------------------------------------------------------------
# Per-append cost at a fixed existing size (the O(n)-slope).
# --------------------------------------------------------------------------
puts "== Per-append cost at a fixed base size (us/append) =="
{false, true}.each do |tags|
  gen = tags ? ->tagged_line(Int32) : ->plain_line(Int32)
  puts tags ? "-- parse_tags = true --" : "-- parse_tags = false --"
  printf "  %-6s  %12s  %12s  %8s\n", "base", "before (us)", "after (us)", "speedup"
  {200, 800, 1600, 3200, 6400}.each do |base|
    batch = 50

    b = make_box(tags)
    base.times { |i| slow_push(b, gen.call(i)) }
    before = Benchmark.measure { batch.times { |i| slow_push(b, gen.call(base + i)) } }.real / batch

    a = make_box(tags)
    base.times { |i| a.push_line gen.call(i) }
    after = Benchmark.measure { batch.times { |i| a.push_line gen.call(base + i) } }.real / batch

    printf "  %-6d  %12.2f  %12.2f  %7.1fx\n", base, before * 1e6, after * 1e6, before / after
  end
  puts
end
