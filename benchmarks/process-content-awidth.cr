require "benchmark"
require "../src/crysterm"

# `Widget#process_content` computes `colwidth = awidth - iwidth` on EVERY frame
# (before its parse-cache guard), using `awidth` with the default `get: false`.
# For the very common `width: nil` (stretch) widget, `awidth(false)` climbs the
# whole ancestor chain — O(depth) — every frame, per widget. This benchmark
# shows that O(depth) scaling and the absolute per-call cost, so we can judge
# whether threading the already-known (O(1)) width into `process_content` is
# worth the extra parameter.
#
# Run:  crystal run --release benchmarks/process-content-awidth.cr

include Crysterm

def build_chain(depth)
  screen = Crysterm::Screen.new
  screen.width = 200
  screen.height = 200
  root = Crysterm::Widget::Box.new
  screen.append root
  leaf = root
  (depth - 1).times do
    child = Crysterm::Widget::Box.new(width: nil, height: nil) # stretch
    leaf.append child
    leaf = child
  end
  {screen, leaf}
end

leaves = {4, 8, 16, 32, 64}.map { |d| {d, build_chain(d)[1]} }

Benchmark.ips do |x|
  leaves.each do |(depth, leaf)|
    x.report("awidth(false) depth=#{depth}") { leaf.awidth(false) }
  end
end
