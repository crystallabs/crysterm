require "../src/crysterm"

# Measures per-frame heap allocation from the parameterless `emit PreRender` /
# `emit Rendered` calls fired per widget/screen each frame. With no listeners
# (the typical app), the splat `emit(type, *args)` overload used to build and
# discard an event object per call; a guard in event_handler's macro now skips
# the allocation. Compare GC bytes/frame against a build with that reverted.
#
# Run:  crystal run --release benchmarks/event-emit.cr

include Crysterm

WIDGETS =  200
FRAMES  = 2000

screen = Screen.new(
  input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
  width: 120, height: 40)

# Flat tree of plain boxes — none subscribe to PreRender/Rendered, so every
# emit has zero listeners (the case the guard optimizes).
WIDGETS.times do |i|
  Widget::Box.new(parent: screen, top: i % 38, left: (i % 100), width: 10, height: 1, content: "w#{i}")
end

# Warm up (first renders allocate caches: lpos, content index, etc.).
50.times { screen._render }

GC.collect
before = GC.stats.total_bytes
FRAMES.times { screen._render }
after = GC.stats.total_bytes

total = after - before
STDERR.printf "widgets=%d frames=%d\n", WIDGETS, FRAMES
STDERR.printf "total allocated: %.2f MB\n", total / 1_048_576.0
STDERR.printf "per frame:       %d bytes  (%.1f bytes/widget)\n",
  total // FRAMES, (total // FRAMES) / WIDGETS.to_f
