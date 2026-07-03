require "benchmark"
require "../src/crysterm"

# Per-frame cost of the draw / terminal-output path (`Screen#draw` in
# `screen_drawing.cr`): the cell-diff of `@lines` vs `@olines` + SGR/cursor byte
# emission. The cracktro harness measures an all-changing scene; this one
# targets the common case — a mostly-static screen where only a few cells
# change per frame — where the per-dirty-row scan and SGR encoding dominate.
#
# `draw` is driven directly: each frame toggles a fixed set of target cells
# between two colored states (forcing the diff to emit them), marks their rows
# dirty, and calls `draw`. Output goes to /dev/null, so B/frame reflects only
# draw's own allocations (the reused @main/@outbuf buffers should make it ~0).
#
# Run:  crystal run --release benchmarks/draw-diff.cr

include Crysterm

W = 200
H =  50

ATTR_A = Attr.pack(0_i64, Attr.pack_color(0xFF5050), Attr.pack_color(0x101010))
ATTR_B = Attr.pack(0_i64, Attr.pack_color(0x50A0FF), Attr.pack_color(0x101010))

def make_screen(devnull) : Screen
  s = Window.new input: IO::Memory.new, output: devnull, error: IO::Memory.new,
    width: W, height: H
  s.width = W
  s.height = H
  s.realloc
  s.draw # prime: @olines mirrors @lines
  s
end

# Target cell sets per scenario (the cells that change each frame).
def targets(kind : String) : Array({Int32, Int32})
  case kind
  when "cursor"    then [{H // 2, W // 2}]
  when "clock"     then (0...8).map { |i| {1, 10 + i} }
  when "scattered" then (0...H).step(2).map { |y| {y, W // 2} }.to_a
  when "vbar"      then (0...H).map { |y| {y, 5} }
  when "full"      then (0...H).flat_map { |y| (0...W).map { |x| {y, x} } }
  else                  [] of {Int32, Int32}
  end
end

KINDS = %w[cursor clock scattered vbar full]

screens = KINDS.to_h { |k| {k, make_screen(File.open("/dev/null", "w"))} }
tgts = KINDS.to_h { |k| {k, targets(k)} }

# `narrowed`: mark each changed cell's column via `Row#mark_dirty(x)` (bounded
# scan of the dirty-column range). Otherwise `dirty = true` (full-width scan,
# pre-change behavior). Both must produce byte-identical output (draw_diff_spec).
@[AlwaysInline]
def frame(s : Screen, ts : Array({Int32, Int32}), even : Bool, narrowed : Bool) : Nil
  attr = even ? ATTR_A : ATTR_B
  ch = even ? 'A' : 'B'
  ts.each do |(y, x)|
    line = s.lines[y]
    cell = line[x]
    cell.attr = attr
    cell.char = ch
    narrowed ? line.mark_dirty(x) : (line.dirty = true)
  end
  s.draw
end

ROUNDS = 20_000

def ns_per_frame(rounds, s, ts, narrowed) : Float64
  best = Float64::INFINITY
  3.times do
    el = Time.measure { rounds.times { |i| frame(s, ts, i.even?, narrowed) } }
    ns = el.total_nanoseconds / rounds
    best = ns if ns < best
  end
  best
end

puts "=" * 64
printf "%-12s %6s %12s %12s %8s\n", "scenario", "cells", "full ns", "narrowed ns", "speedup"
puts "=" * 64
KINDS.each do |k|
  ts = tgts[k]
  s = screens[k]
  full = ns_per_frame(ROUNDS, s, ts, false)
  narrow = ns_per_frame(ROUNDS, s, ts, true)
  printf "%-12s %6d %12.0f %12.0f %7.2fx\n", k, ts.size, full, narrow, full / narrow
end
