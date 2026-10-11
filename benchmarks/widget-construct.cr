require "../src/crysterm"

# Per-widget construction and first-frame cost: instance sizes of the widget
# and style objects, bytes and time per `Widget::Box` construction under a
# window, the allocation of the first repaint (which materializes every
# style's lazily-created box sub-objects), and the retained heap afterwards.
#
# Run:  crystal run --release benchmarks/widget-construct.cr

include Crysterm

N = (ARGV[0]? || "20000").to_i

def report(label, bytes, ms, n)
  STDERR.printf "%-28s %9.1f B/widget  %7.3f µs/widget  (%d widgets)\n", label, bytes.to_f / n, ms * 1000.0 / n, n
end

STDERR.puts "instance_sizeof Widget=#{instance_sizeof(Widget)} Box=#{instance_sizeof(Widget::Box)} " \
            "Style=#{instance_sizeof(Style)} Styles=#{instance_sizeof(Styles)} " \
            "Border=#{instance_sizeof(Border)} Padding=#{instance_sizeof(Padding)} " \
            "Margin=#{instance_sizeof(Margin)} Shadow=#{instance_sizeof(Shadow)}"

s = Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
  width: 269, height: 80, optimization: Crysterm::OptimizationFlag::None)

# Warm the window once (its own lazy state is not what this measures).
Widget::Box.new(parent: s, top: 0, left: 0, width: 1, height: 1, content: "w")
s.repaint
GC.collect

# Construction: N boxes appended to the window.
b0 = GC.stats.total_bytes
t0 = Time.instant
boxes = Array(Widget::Box).new(N)
N.times do |i|
  boxes << Widget::Box.new(parent: s, top: i % 80, left: (i // 80) % 269, width: 1, height: 1, content: "·")
end
dt = (Time.instant - t0).total_milliseconds
report("construct", GC.stats.total_bytes - b0, dt, N)

# First frame: every style's box sub-objects are read by the render path.
GC.collect
b0 = GC.stats.total_bytes
t0 = Time.instant
s.repaint
dt = (Time.instant - t0).total_milliseconds
report("first repaint", GC.stats.total_bytes - b0, dt, N)

# Steady frame, for reference.
GC.collect
b0 = GC.stats.total_bytes
t0 = Time.instant
s.repaint
dt = (Time.instant - t0).total_milliseconds
report("steady repaint", GC.stats.total_bytes - b0, dt, N)

GC.collect
STDERR.printf "heap after: %d KiB (%.1f KiB/widget)\n", GC.stats.heap_size // 1024, GC.stats.heap_size / 1024.0 / N

# Keep the widgets alive to the end so the heap figure counts them.
STDERR.puts "widgets: #{boxes.size + 1}"
