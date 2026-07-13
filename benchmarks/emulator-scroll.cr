require "benchmark"
require "../src/crysterm"

# `TerminalEmulator` stores its grid as `Array(Array(Cell))` with a heap-`class`
# `Cell` per occupied cell. Every scrolled line allocates a fresh `blank_line`
# (`@cols` `Cell` objects + the array), and once scrollback fills, `@lines.shift`
# is O(scrollback) per scrolled line. Drives heavy scrolling output (the
# emulator's hottest real path) and reports throughput + bytes allocated, to
# judge whether converting `Cell` to a struct (+ `Deque` scrollback) is worth
# the cross-cutting rewrite of every in-place `line[x].attr = …` mutation.
#
# Run:  crystal run --release benchmarks/emulator-scroll.cr

include Crysterm

COLS  =      80
ROWS  =      24
LINES = 200_000

# Realistic-ish line: text then a newline. ASCII so 1 byte/char.
payload = String.build do |s|
  LINES.times { |i| s << "The quick brown fox jumps over line number "; s << i; s << '\n' }
end
bytes = payload.to_slice

def gc_heap : UInt64
  GC.stats.total_bytes
end

3.times do |run|
  em = TerminalEmulator.new COLS, ROWS, Crysterm::Window::DEFAULT_ATTR
  GC.collect
  before = gc_heap
  t0 = Time.instant
  em.feed bytes
  dt = Time.instant - t0
  allocated = gc_heap - before
  lines_per_s = (LINES / dt.total_seconds).to_i
  printf "run %d: %8.1f ms   %10d lines/s   %8.1f MB allocated (%.0f B/line)\n",
    run, dt.total_milliseconds, lines_per_s, allocated / 1.0e6, allocated.to_f / LINES
end
