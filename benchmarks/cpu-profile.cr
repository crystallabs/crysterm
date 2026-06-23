require "../src/crysterm"

# A sustained render loop over a heavy, STATIC scene, so an external sampling
# profiler (`sample <pid>`) can attribute CPU time within the render/draw path.
# Static content means we profile the per-frame COMPOSITING + DRAW-DIFF hot path
# (the ~25µs the frame-profile attributed to render), not content reparse.
#
# Usage:
#   crystal build --release benchmarks/cpu-profile.cr -o /tmp/cpuprof
#   /tmp/cpuprof & ; sample $! 8 -f /tmp/sample.txt ; wait
#
# Runs for ~SECONDS wall-clock then exits.

include Crysterm

SECONDS = 12.0

screen = Screen.new(
  input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
  width: 200, height: 60)

# ~150 bordered panels with content laid across the screen — a heavy but
# realistic compositing load.
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
50.times { screen._render }

frames = 0
deadline = Time.instant + SECONDS.seconds
until Time.instant >= deadline
  100.times { screen._render }
  frames += 100
end

STDERR.printf "rendered %d frames in ~%.0fs (%.1f µs/frame)\n",
  frames, SECONDS, SECONDS * 1_000_000 / frames
