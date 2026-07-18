# Headless reproduction of examples/features/donut.cr's hot path: a few disjoint
# top-level widgets, each updating per frame. Measures per-frame render cost ON
# (damage tracking) vs OFF (full recomposite). Size via COLUMNS/LINES (default 80x24).
#
# Run:  crystal run --release benchmarks/donut-profile.cr

require "../src/crysterm"
include Crysterm

FRAMES = (ENV["FRAMES"]? || "600").to_i

def run(label, opt)
  s = Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    optimization: opt)

  cpu = Widget::Graph::Donut.new parent: s, top: 0, left: 0, width: 20, height: 11,
    value: 0, label: "CPU", fill_color: 0x40E0D0, style: Style.new(fg: "white", bg: "#101820", border: true)
  mem = Widget::Graph::Donut.new parent: s, top: 0, left: 21, width: 20, height: 11,
    value: 0, label: "MEM", fill_color: 0xE0A040, show_track: true, track_color: 0x404850,
    style: Style.new(fg: "white", bg: "#101820", border: true)
  gl = Widget::GaugeList.new parent: s, top: 0, left: 42, width: 34, height: 11,
    style: Style.new(fg: "white", bg: "#101820", border: true)
  %w[disk net gpu pwr swap io].each { |n| gl.add_item n, 0 }

  Widget::Fps.new parent: s, top: "100%-1", left: 0,
    format: "FPS %5s  (R %5s / D %5s)", args: [Widget::Fps::Metric::Fps, Widget::Fps::Metric::Render, Widget::Fps::Metric::Draw],
    style: Style.new(fg: "black", bg: 0x40e0c0)

  phase = 0.0
  step = -> {
    cpu.value = (Math.sin(phase) * 0.5 + 0.5) * 100
    mem.value = (Math.cos(phase * 0.7) * 0.5 + 0.5) * 100
    gl.items.each_with_index { |g, i| gl[i] = (Math.sin(phase + i) * 0.5 + 0.5) * 100 }
    phase += 0.025
  }

  5.times { step.call; s._render }

  GC.collect
  before = GC.stats.total_bytes
  rsum = 0_i64; dsum = 0_i64
  wall = Time.measure do
    FRAMES.times do
      step.call
      s._render
      rsum += s.render_rate
      dsum += s.draw_rate
    end
  end
  alloc = GC.stats.total_bytes - before

  fast = s.responds_to?(:damage_fast_frames) ? s.damage_fast_frames : 0
  full = s.responds_to?(:damage_full_frames) ? s.damage_full_frames : 0
  STDERR.printf "%-26s  wall/frame: %7.1f µs   alloc/frame: %8d bytes   render-eq %d fps  draw-eq %d fps\n",
    label, wall.total_microseconds / FRAMES, alloc // FRAMES, rsum // FRAMES, dsum // FRAMES
  if opt.damage_tracking?
    STDERR.printf "%-26s  damage fast frames: %d  full frames: %d\n", "", fast, full
  end
end

probe = Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
STDERR.puts "\n=== donut: #{probe.awidth}x#{probe.aheight}, #{FRAMES} frames (4 disjoint top-level widgets, all update/frame) ==="
run "OFF (full recomposite)", OptimizationFlag::None
run "ON  (damage tracking)", OptimizationFlag::DamageTracking
