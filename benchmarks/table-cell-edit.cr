require "../src/crysterm"

# One cell edit in a large table (`TextTable#set_cell_text`) that changes a
# column's width, so every row of the table is re-rendered: a 4-column table
# of 200 and of 1,000 rows, on a bare document and on one shown in a
# `TextEdit`. The edit alternates a cell between a short and a long text, so
# each one widens or narrows the column.
#
# Reports ms per edit, the `ContentsChanged` steps one edit makes, and ms
# per undo of one.
#
# Run:  crystal run --release benchmarks/table-cell-edit.cr

private def table_markdown(rows : Int32) : String
  String.build do |io|
    io << "| id | name | state | note |\n|---|---|---|---|\n"
    rows.times do |i|
      io << "| " << i << " | item " << i << " | ok | n" << i << " |\n"
    end
  end
end

private def bench_table(rows : Int32, view : Bool)
  doc = Crysterm::TextDocument.from_markdown(table_markdown(rows))
  if view
    s = Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
      width: 100, height: 30, optimization: Crysterm::OptimizationFlag::None)
    Crysterm::Widget::TextEdit.new(parent: s, top: 0, left: 0, width: 90, height: 25, document: doc)
    s.repaint
  end
  table = doc.cursor(0).current_table || raise "no table"
  steps = 0
  doc.on(Crysterm::Event::ContentsChanged) { steps += 1 }

  texts = {"a much longer state text", "ok"}
  table.set_cell_text(3, 2, texts[0]) # warm
  table.set_cell_text(3, 2, texts[1])
  edits = rows >= 1000 ? 6 : 20
  steps = 0
  GC.collect
  t0 = Time.instant
  edits.times { |i| table.set_cell_text(3, 2, texts[i % 2]) }
  dt = Time.instant - t0
  per_edit = steps // edits

  t0 = Time.instant
  edits.times { doc.undo }
  du = Time.instant - t0
  STDERR.printf "  %4d rows%s  %9.2f ms/edit  %6d steps/edit  %9.2f ms/undo\n",
    rows, view ? " (in a TextEdit)" : "                ", dt.total_milliseconds / edits, per_edit,
    du.total_milliseconds / edits
end

STDERR.puts "set_cell_text widening or narrowing a column:"
{200, 1000}.each do |rows|
  bench_table rows, false
  bench_table rows, true
end
