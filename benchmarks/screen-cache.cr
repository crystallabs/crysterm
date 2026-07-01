require "benchmark"
require "../src/crysterm"

# `Widget#screen?` derives the owning `Screen` by walking parent→…→root,
# read several times per widget per frame — on a deep tree the O(depth) walk
# adds up.
#
# Fix: memoize the resolved screen on each widget (`@screen_cache`),
# invalidated across the subtree only on reparenting. Compares, at several
# depths:
#   * OLD: the uncached walk (reproduced inline as `walk_to_screen`), and
#   * NEW: the live, memoized `Widget#screen?`.
#
# Run:  crystal run --release benchmarks/screen-cache.cr

include Crysterm

# Pre-cache `screen?` body: climb the parent chain to the top-level widget.
def walk_to_screen(w : Widget) : Crysterm::Screen?
  if parent = w.parent
    walk_to_screen parent
  else
    w.screen?
  end
end

def leaf_at(depth) : Widget
  screen = Crysterm::Screen.new
  screen.width = 200
  screen.height = 200
  node = Crysterm::Widget::Box.new
  screen.append node
  (depth - 1).times do
    child = Crysterm::Widget::Box.new
    node.append child
    node = child
  end
  node
end

{4, 16, 64}.each do |depth|
  leaf = leaf_at depth
  leaf.screen? # warm the cache

  puts "depth=#{depth}:"
  Benchmark.ips do |x|
    x.report("  OLD walk_to_screen") do
      s = nil
      1000.times { s = walk_to_screen leaf }
      s
    end
    x.report("  NEW screen? (cached)") do
      s = nil
      1000.times { s = leaf.screen? }
      s
    end
  end
  puts
end
