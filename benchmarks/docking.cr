require "benchmark"
require "../src/crysterm"

# Per-frame cost of the border-docking pass (`Crysterm::Docking.dock`), invoked
# every frame from `Screen#_dock` when `dock_borders` is on. It scans the full
# screen width of every "stop" row (rows that emitted a horizontal border
# segment), testing each cell against the box-drawing `ANGLES` set and
# rejoining junctions. On a wide screen most cells on a stop row are
# blank/non-box, so the per-cell reject path dominates.
#
# Method: build a headless screen with several adjacent bordered boxes (real
# border rows and crossing junctions), render once to populate `@lines` and
# `@_dock_stops`, then drive `Docking.dock` directly in a loop. Docking is
# idempotent on an already-docked grid, so repeated calls measure the scan
# itself.
#
# Run:  crystal run --release benchmarks/docking.cr

include Crysterm

WIDTH  = 200
HEIGHT =  50

def build : {Crysterm::Screen, Hash(Int32, Bool)}
  s = Screen.new input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: WIDTH, height: HEIGHT
  s.dock_borders = true

  # Adjacent bordered boxes whose borders overlap/touch, producing many
  # docking junctions and stop rows.
  rows = 4
  cols = 6
  bw = 12
  bh = 8
  rows.times do |r|
    cols.times do |c|
      Widget::Box.new parent: s,
        left: c * (bw - 1), top: r * (bh - 1),
        width: bw, height: bh,
        style: Style.new(border: Border.new(type: :line))
    end
  end

  s._render
  {s, s._dock_stops.dup}
end

s, stops = build
contrast = s.dock_contrast
lines = s.lines
width = s.awidth

puts "stop rows: #{stops.size}, width: #{width}"

GC.collect
before = GC.stats.total_bytes
ROUNDS = 20_000
ROUNDS.times { Docking.dock lines, stops, width, contrast }
puts "B/frame: #{((GC.stats.total_bytes - before).to_f / ROUNDS).round(1)}"

Benchmark.ips do |x|
  x.report("dock") { Docking.dock lines, stops, width, contrast }
end
