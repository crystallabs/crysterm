require "../src/crysterm"

# Per-frame render profile for the bar-chart widgets (Bar / StackedBar). Both
# rebuild their tagged glyph grid every frame via `BarChart#plot_row`, once per
# plot row. Animates a rolling-window dataset and re-renders on the
# full-recomposite path, reporting heap allocation per frame plus wall time.
#
# Run:  crystal run --release benchmarks/bar-render.cr

include Crysterm

FRAMES = (ENV["FRAMES"]? || "4000").to_i

def bench_bar(label, bar_width, bar_spacing, n)
  s = Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 120, height: 40,
    optimization: Crysterm::OptimizationFlag::None)

  bar = Widget::Graph::Bar.new(
    parent: s, top: 0, left: 0, width: 100, height: 20,
    max: 100.0, bar_width: bar_width, bar_spacing: bar_spacing,
    colors: %w[green cyan yellow red magenta blue])
  bar.values = Array.new(n) { |i| (i * 7 % 100).to_f }

  t = 0
  step = -> {
    t += 1
    bar.values = Array.new(n) { |i| ((i * 7 + t * 3) % 100).to_f }
  }

  50.times { step.call; s.repaint } # warm caches

  GC.collect
  before = GC.stats.total_bytes
  wall = Time.measure { FRAMES.times { step.call; s.repaint } }
  alloc = GC.stats.total_bytes - before
  STDERR.printf "%-26s alloc/frame: %7d bytes   wall/frame: %6.1f µs\n",
    label, alloc // FRAMES, wall.total_microseconds / FRAMES
end

STDERR.puts "#{FRAMES} frames each, full-recomposite path (animated rolling data)"
bench_bar "Bar w1 s0 n40", 1, 0, 40
bench_bar "Bar w4 s2 n12", 4, 2, 12
bench_bar "Bar w6 s3 n8", 6, 3, 8
