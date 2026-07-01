require "benchmark"
require "../src/crysterm"

# Benchmark for the CSS-cascade style-reset hot path.
#
# The cascade (CSS::Cascade.apply_sheets) is not per-frame, but every (re)cascade
# resets EVERY recompute candidate to a fresh dup of its pristine styles —
# `widget.styles = widget.css_base_styles.deep_dup` — then dups a per-state base
# style for every touched (widget, state). On a deep tree that's thousands of
# `Style#dup` calls, each allocating the Style plus its `padding`/`margin`/
# `shadow`/`border` sub-objects.
#
# The DETERMINISTIC metric (bytes/allocations per batch) is the real result; ips
# figures are noise-dominated on a dev box.
#
# Run:  crystal run --release benchmarks/style-cascade.cr

include Crysterm

ROUNDS = 200_000

def alloc_mb(n, &block)
  GC.collect
  before = GC.stats.total_bytes
  n.times { block.call }
  (GC.stats.total_bytes - before) / (1024.0 * 1024.0)
end

def alloc_bytes(n, &block)
  GC.collect
  before = GC.stats.total_bytes
  n.times { block.call }
  (GC.stats.total_bytes - before) // n
end

puts "=" * 72
puts "Crysterm style cascade hot-path"
puts "=" * 72

# Common case: no padding/margin/shadow/border set (color-only theme).
plain = Style.new
# A style that sets the box sub-objects.
boxed = Style.new(padding: 1, margin: 1, shadow: true, border: true)

puts "\n#1  Style#dup  (per state per widget, every cascade)"
Benchmark.ips do |x|
  x.report("plain Style#dup") { plain.dup }
  x.report("boxed Style#dup") { boxed.dup }
end
puts "  alloc: plain #{alloc_bytes(ROUNDS) { plain.dup }} B/op   boxed #{alloc_bytes(ROUNDS) { boxed.dup }} B/op"

# Styles#deep_dup of a default Styles (only `normal`, no extra states) — what
# `css_base_styles.deep_dup` does for a plain widget.
styles = Styles.default
puts "\n#2  Styles#deep_dup  (per recompute candidate, every cascade)"
Benchmark.ips do |x|
  x.report("Styles#deep_dup") { styles.deep_dup }
end
puts "  alloc: #{alloc_bytes(ROUNDS) { styles.deep_dup }} B/op"

# ---------------------------------------------------------------------------
# Case.fold_property / fold_keyword — run per declaration per (widget, state)
# in the cascade inner loop. CSS tokens are usually already-lowercase ASCII,
# where the OLD `String#downcase` still allocated a fresh String.
puts "\n#3  Case.fold_property / fold_keyword  (per declaration, every cascade)"
props = ["color", "background-color", "border-left-width", "font-weight", "padding-top"]
kws = ["none", "bold", "dashed", "hidden", "infinite"]
old_fold_prop = ->(name : String) { name.starts_with?("--") ? name : name.downcase }
Benchmark.ips do |x|
  x.report("OLD fold_property (downcase)") { props.each { |p| old_fold_prop.call p } }
  x.report("NEW fold_property") { props.each { |p| Crysterm::CSS::Case.fold_property p } }
  x.report("OLD fold_keyword  (downcase)") { kws.each { |k| k.downcase } }
  x.report("NEW fold_keyword") { kws.each { |k| Crysterm::CSS::Case.fold_keyword k } }
end
puts "  alloc fold_property: OLD #{alloc_bytes(ROUNDS) { props.each { |p| old_fold_prop.call p } }} B/op" \
     "  vs NEW #{alloc_bytes(ROUNDS) { props.each { |p| Crysterm::CSS::Case.fold_property p } }} B/op  (x5 tokens)"
puts "  alloc fold_keyword:  OLD #{alloc_bytes(ROUNDS) { kws.each { |k| k.downcase } }} B/op" \
     "  vs NEW #{alloc_bytes(ROUNDS) { kws.each { |k| Crysterm::CSS::Case.fold_keyword k } }} B/op  (x5 tokens)"

# Correctness: folded result must equal a plain downcase (custom props aside).
{"color" => "color", "Background-Color" => "background-color", "BORDER" => "border",
 "--Foo" => "--Foo", "PX" => "px", "ease-in-out" => "ease-in-out"}.each do |inp, want|
  gotp = Crysterm::CSS::Case.fold_property inp
  raise "fold_property(#{inp.inspect}) = #{gotp.inspect}, want #{want.inspect}" unless gotp == want
end
{"none" => "none", "DASHED" => "dashed", "Bold" => "bold"}.each do |inp, want|
  raise "fold_keyword mismatch" unless Crysterm::CSS::Case.fold_keyword(inp) == want
end
puts "  correctness: OK (fold_property/fold_keyword match downcase semantics)"

# ---------------------------------------------------------------------------
# ColorValue.resolve — run per color declaration (fg/bg/border/...) per widget
# on every cascade. The common bare hex/named color short-circuits to the value
# itself; the OLD `v.downcase` still allocated a throwaway copy.
puts "\n#4  ColorValue.resolve  (per color declaration, every cascade)"
colors = ["#1e1e2e", "#ff8800", "red", "steelblue", "#cdd6f4"]
old_resolve = ->(value : String) do
  v = value.strip
  dv = v.downcase
  if dv == "transparent"
    -1
  elsif dv.includes?("gradient")
    nil
  elsif dv.starts_with?("rgb") || dv.starts_with?("hsl")
    nil
  else
    v
  end
end
Benchmark.ips do |x|
  x.report("OLD resolve (downcase)") { colors.each { |c| old_resolve.call c } }
  x.report("NEW ColorValue.resolve") { colors.each { |c| Crysterm::CSS::ColorValue.resolve(c, nil) } }
end
puts "  alloc: OLD #{alloc_bytes(ROUNDS) { colors.each { |c| old_resolve.call c } }} B/op" \
     "  vs NEW #{alloc_bytes(ROUNDS) { colors.each { |c| Crysterm::CSS::ColorValue.resolve(c, nil) } }} B/op  (x5 colors)"

# Correctness: the `else` branch returns the ORIGINAL-case value (preserved for
# downstream Colors.convert) in both old and new; NEW must dispatch identically
# to a plain downcase.
raise "hex case preserved" unless Crysterm::CSS::ColorValue.resolve("#1E1E2E", nil) == "#1E1E2E"
raise "named case preserved" unless Crysterm::CSS::ColorValue.resolve("RED", nil) == "RED"
raise "transparent" unless Crysterm::CSS::ColorValue.resolve("TRANSPARENT", nil) == -1
raise "currentColor" unless Crysterm::CSS::ColorValue.resolve("currentColor", 0x123456) == 0x123456
raise "rgb (mixed case dispatch)" unless Crysterm::CSS::ColorValue.resolve("RGB(255, 136, 0)", nil) == 0xff8800
raise "hsl (mixed case dispatch)" unless Crysterm::CSS::ColorValue.resolve("HSL(0, 100%, 50%)", nil) == 0xff0000
puts "  correctness: OK (case dispatch + original-case passthrough preserved; transparent/currentColor/rgb/hsl intact)"
