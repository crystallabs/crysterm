require "../src/crysterm"

# Per-frame render profile for the table widgets (Table / ListTable). Both run
# their full `draw_borders` (and, for Table, the per-cell text-attr pass) on
# every render. Pins the screen to the full-recomposite path
# (OptimizationFlag::None) and reports heap allocation per frame plus wall time.
#
# Run:  crystal run --release benchmarks/table-render.cr

include Crysterm

FRAMES = (ENV["FRAMES"]? || "4000").to_i

# A header row plus body rows, several columns, bordered.
def make_rows(cols, body)
  rows = [Array.new(cols) { |c| "Col#{c}" }]
  body.times do |r|
    rows << Array.new(cols) { |c| "r#{r}c#{c}" }
  end
  rows
end

def bench_table(label, cols, body)
  s = Screen.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 120, height: 40,
    optimization: Crysterm::OptimizationFlag::None)

  Widget::Table.new(
    parent: s, top: 0, left: 0,
    rows: make_rows(cols, body),
    style: Style.new(border: true))

  50.times { s._render } # warm caches

  GC.collect
  before = GC.stats.total_bytes
  wall = Time.measure { FRAMES.times { s._render } }
  alloc = GC.stats.total_bytes - before
  STDERR.printf "%-22s alloc/frame: %6d bytes   wall/frame: %6.1f µs\n",
    label, alloc // FRAMES, wall.total_microseconds / FRAMES
end

def bench_listtable(label, cols, body)
  s = Screen.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 120, height: 40,
    optimization: Crysterm::OptimizationFlag::None)

  Widget::ListTable.new(
    parent: s, top: 0, left: 0, width: 80, height: 20,
    rows: make_rows(cols, body),
    style: Style.new(border: true))

  50.times { s._render }

  GC.collect
  before = GC.stats.total_bytes
  wall = Time.measure { FRAMES.times { s._render } }
  alloc = GC.stats.total_bytes - before
  STDERR.printf "%-22s alloc/frame: %6d bytes   wall/frame: %6.1f µs\n",
    label, alloc // FRAMES, wall.total_microseconds / FRAMES
end

STDERR.puts "#{FRAMES} frames each, full-recomposite path"
bench_table "Table 6x20", 6, 20
bench_table "Table 10x40", 10, 40
bench_listtable "ListTable 6x20", 6, 20
bench_listtable "ListTable 10x40", 10, 40
