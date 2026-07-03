require "benchmark"
require "../src/crysterm"

# `Widget#process_content` computes `colwidth = awidth - iwidth` on every
# frame (before its parse-cache guard), using `awidth` with default
# `get: false`. For a `width: nil` (stretch) widget, `awidth(false)` climbs
# the whole ancestor chain — O(depth) — every frame, per widget. This
# benchmarks that scaling and per-call cost, to judge whether threading the
# already-known O(1) width into `process_content` is worth the extra param.
#
# Run:  crystal run --release benchmarks/process-content-awidth.cr

include Crysterm

def build_chain(depth)
  screen = Crysterm::Window.new
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
