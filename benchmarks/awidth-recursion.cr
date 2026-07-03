require "benchmark"
require "../src/crysterm"

# `Widget#awidth(get: false)` climbs the ancestor chain. The nil-width +
# string-left branch used to call `parent.awidth` TWICE (the `resolve_dimension`
# base and the width subtraction), so each level doubled the work below it —
# O(2^depth) for a chain of centered, auto-width boxes (a completely ordinary
# config). Sharing the one `parent.awidth` value collapses that to O(depth).
#
# Measured at depth 16:
#   combinatorial (str-left, nil-width)  OLD 2.52ms, 1.0MB/op   NEW 704ns, 256B/op
#   (linear int-left/nil-width was already ~250ns and is unchanged.)

def build_chain(depth, &block : Crysterm::Widget::Box -> Nil)
  screen = Crysterm::Window.new
  screen.width = 200
  screen.height = 200
  root = Crysterm::Widget::Box.new
  screen.append root
  block.call root
  leaf = root
  (depth - 1).times do
    child = Crysterm::Widget::Box.new
    block.call child
    leaf.append child
    leaf = child
  end
  {screen, leaf}
end

DEPTH = 16

# Scenario A: integer left, nil width (stretch). 1 parent.awidth call/level → O(depth).
_, leaf_lin = build_chain(DEPTH) { |w| w.left = 1; w.width = nil }

# Scenario B: string left ("center"), nil width. 2 parent.awidth calls/level → O(2^depth).
_, leaf_exp = build_chain(DEPTH) { |w| w.left = "center"; w.width = nil }

puts "depth = #{DEPTH}"
Benchmark.ips do |x|
  x.report("awidth(false)  linear  (int-left, nil-width)") { leaf_lin.awidth }
  x.report("awidth(false)  combinatorial (str-left, nil-width)") { leaf_exp.awidth }
end
