require "../src/crysterm"

# Sustained render loop over a heavy, static scene, for an external sampling
# profiler (`sample <pid>`) to attribute CPU time in the render/draw path.
# Static content isolates the per-frame compositing + draw-diff hot path
# (the ~25µs the frame-profile attributed to render), not content reparse.
#
# Usage:
#   crystal build --release benchmarks/cpu-profile.cr -o /tmp/cpuprof
#   /tmp/cpuprof & ; sample $! 8 -f /tmp/sample.txt ; wait
#
# Runs for ~SECONDS wall-clock then exits.

include Crysterm

SECONDS = 12.0

# Pinned to the full-recomposite path: damage tracking is on by default and
# a static scene would hit the no-change fast path (~0.2 µs/frame), leaving
# nothing for the profiler to attribute.
screen = Window.new(
  input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
  width: 200, height: 60,
  optimization: Crysterm::OptimizationFlag::None)

# ~150 bordered panels laid across the screen — heavy but realistic load.
15.times do |row|
  10.times do |col|
    Widget::Box.new(
      parent: screen,
      top: row * 4, left: col * 20,
      width: 19, height: 4,
      style: Style.new(border: true, fg: "white", bg: "blue"),
      content: "cell #{row},#{col}\nval #{row * col}")
  end
end

# Warm up caches.
50.times { screen.repaint }

frames = 0
deadline = Time.instant + SECONDS.seconds
until Time.instant >= deadline
  100.times { screen.repaint }
  frames += 100
end

STDERR.printf "rendered %d frames in ~%.0fs (%.1f µs/frame)\n",
  frames, SECONDS, SECONDS * 1_000_000 / frames
