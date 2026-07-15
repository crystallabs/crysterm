require "benchmark"
require "../src/crysterm"

# Per-frame cost of the child-arranging layout engines (`src/layout/*`). Each
# engine's `#arrange` runs on every `Widget#_render` of a container with a
# layout installed, so any per-frame allocation there is paid every frame.
#
# Method: build one headless screen per engine holding a single container with
# N identical children, prime it with a full `s._render`, then measure
# `layout.render_children(container)` directly in a loop (a repeated
# `s._render` would short-circuit on the clean tree and skip `arrange`).
# Children's geometry is unchanged between calls, so setters no-op and child
# re-renders stay cheap, leaving the engine's own per-frame collections as the
# dominant, deterministic B/frame signal. ns/frame is noisy.
#
# Run:  crystal run --release benchmarks/layout-arrange.cr

include Crysterm

N = 12 # children per container

# Builds a fresh headless screen with one container using `layout`, populated
# by the block, primes it, and returns {layout, container}.
def make(layout : Layout, & : Widget -> _) : {Layout, Widget}
  s = Window.new input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new
  box = Widget::Box.new parent: s, left: 0, top: 0, width: 60, height: 20,
    layout: layout, overflow: Crysterm::Overflow::Ignore
  yield box
  s._render # prime (establishes container.lpos + first-frame child geometry)
  {layout, box}
end

def plain_children(box : Widget)
  N.times { Widget::Box.new parent: box, width: 4, height: 2 }
end

cases = {
  "manual" => make(Layout::Manual.new) { |b| plain_children b },
  "hbox"   => make(Layout::HBox.new(gap: 1)) { |b| plain_children b },
  "vbox"   => make(Layout::VBox.new(gap: 1)) { |b| plain_children b },
  "grid"   => make(Layout::Grid.new(columns: 4)) { |b|
    Widget::Box.new parent: b, layout_hint: Layout::Grid::Hint.new(row: 0, column: 0, column_span: 2)
    (N - 1).times { Widget::Box.new parent: b }
  },
  "masonry" => make(Layout::Masonry.new) { |b| plain_children b },
  "uniform" => make(Layout::UniformGrid.new) { |b| plain_children b },
  "wrap"    => make(Layout::Wrap.new) { |b| plain_children b },
  "form"    => make(Layout::Form.new(label_width: 10)) { |b|
    N.times { Widget::Box.new parent: b, height: 1 }
  },
  "stack" => make(Layout::Stack.new(0)) { |b| plain_children b },
}

ROUNDS = 20_000

def bytes_per_frame(rounds, layout, box) : Float64
  GC.collect
  before = GC.stats.total_bytes
  rounds.times { layout.render_children(box) }
  (GC.stats.total_bytes - before).to_f / rounds
end

puts "=" * 56
puts "Layout engines — B/frame  (#{N} children, #{ROUNDS} rounds)"
puts "=" * 56
cases.each do |name, (layout, box)|
  printf "  %-9s %9.1f B/frame\n", name, bytes_per_frame(ROUNDS, layout, box)
end

puts "\n" + "=" * 56
puts "Layout engines — ns/frame  (ips, NOISY)"
puts "=" * 56
Benchmark.ips do |x|
  cases.each do |name, (layout, box)|
    x.report(name) { layout.render_children(box) }
  end
end
