require "../src/crysterm"

# Measures per-frame heap allocation attributable to the parameterless
# `emit PreRender` / `emit Rendered` calls fired per widget (and per screen)
# every frame. With no listeners on those events (the typical app), the splat
# `emit(type, *args)` overload used to build — and immediately discard — an
# event object per call; the guard added to event_handler's macro now skips the
# allocation entirely. Compare GC bytes/frame on this build vs a build with the
# macro change reverted.
#
# Run:  crystal run --release benchmarks/event-emit.cr

include Crysterm

WIDGETS = 200
FRAMES  = 2000

screen = Screen.new(
  input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
  width: 120, height: 40)

# A flat tree of plain boxes — none subscribe to PreRender/Rendered, so every
# such emit this frame has zero listeners (the case the guard optimizes).
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
