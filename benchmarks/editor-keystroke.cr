require "../src/crysterm"

# Cost of one keystroke in a multi-line `PlainTextEdit`: the document edit
# itself plus the frame that shows it (`paint` → `refresh_value` →
# `process_content` → render), on ASCII buffers of 2,000 and 20,000 lines and
# a non-ASCII one of 2,000 lines, with the caret parked mid-buffer. Every
# fifth line is wider than the box so some lines wrap to several rows.
#
# Reports µs and KiB allocated per keystroke, next to a repaint with no edit
# (the fixed per-frame cost) and an edit with no repaint (the document's own
# share), so the display update's share is visible.
#
# Run:  crystal run --release benchmarks/editor-keystroke.cr

include Crysterm

def make_editor(lines : Int32, unicode : Bool)
  s = Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 100, height: 30, optimization: Crysterm::OptimizationFlag::None)
  text = String.build do |io|
    lines.times do |i|
      io << '\n' if i > 0
      io << "line " << i << (unicode ? ": the quick brown fox — über the lazy dog, café" : ": the quick brown fox jumps over the lazy dog again")
      io << " and keeps running across the whole field until it wraps" if i % 5 == 0
    end
  end
  e = Widget::PlainTextEdit.new(parent: s, top: 0, left: 0, width: 80, height: 25, content: text)
  s.repaint
  e.cursor_pos = e.buf_size // 2 + 10
  s.repaint
  {s, e}
end

def measure(label, n, &block)
  block.call # warm
  GC.collect
  b0 = GC.stats.total_bytes
  t0 = Time.instant
  n.times { block.call }
  dt = Time.instant - t0
  db = GC.stats.total_bytes - b0
  STDERR.printf "  %-34s %9.1f µs  %8.1f KiB alloc\n", label, dt.total_microseconds / n, db.to_f / n / 1024
end

# The non-ASCII buffer: every visible row's codepoint index is a materialized
# `chars` array rather than a byte view, so the per-row index cache shows.
[{2_000, false}, {20_000, false}, {2_000, true}].each do |(lines, unicode)|
  s, e = make_editor(lines, unicode)
  STDERR.puts "#{lines} lines (#{e.wrapped_lines.size} rows)#{unicode ? ", non-ASCII" : ""}:"
  n = lines >= 20_000 ? 200 : 1000
  measure("repaint only", n) { s.repaint }
  measure("insert_text only (no repaint)", n) { e.insert_text("x") }
  s.repaint
  measure("keystroke = insert_text + repaint", n) do
    e.insert_text("x")
    s.repaint
  end
  measure("backspace + repaint", n) do
    e._listener Crysterm::Event::KeyPress.new('\0', Tput::Key::Backspace)
    s.repaint
  end
end
