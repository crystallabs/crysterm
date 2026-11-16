require "../src/crysterm"

# Per-frame cost of `Widget::PlainTextEdit`'s row decorations
# (`highlight_current_line` / extra selections) over one very long wrapped
# paragraph. Every painted row asks `extra_selections_for_row`, which maps
# the row to its buffer bounds; a mapping that walks the paragraph's
# preceding wrapped pieces per row makes a frame at the paragraph's end cost
# O(viewport rows × paragraph rows).
#
# Method: a headless 100x40 window holding one editor with a single
# paragraph of `CHARS` characters (so ~CHARS/98 wrapped rows), caret parked
# at the end (view scrolled to the bottom); each frame marks the editor
# dirty and repaints. Reported for the plain editor and with the
# current-line highlight on, in µs and bytes per frame.
#
# Run:  crystal run --release benchmarks/plaintext-highlight.cr
#       CHARS=1000000 ./plaintext-highlight

alias CT = Crysterm
alias CW = CT::Widgets

CT::Config.set "screen.headless", CT::Headless::Always

CHARS  = (ENV["CHARS"]? || "200000").to_i
FRAMES = (ENV["FRAMES"]? || "300").to_i

def measure(label : String, s : CT::Window, w : CT::Widget) : Nil
  5.times { w.update!; s.repaint }
  GC.collect
  b0 = GC.stats.total_bytes
  t0 = Time.instant
  FRAMES.times do
    w.update!
    s.repaint
  end
  dt = (Time.instant - t0).total_microseconds / FRAMES
  db = (GC.stats.total_bytes - b0) / FRAMES
  printf "  %-30s %9.1f µs/frame  %8d B/frame\n", label, dt, db
end

text = String.build do |io|
  i = 0
  while io.bytesize < CHARS
    io << "word" << (i % 97) << ' '
    i += 1
  end
end

{false, true}.each do |highlight|
  s = CT::Window.new input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 100, height: 40
  ed = CW::PlainTextEdit.new parent: s, top: 0, left: 0, width: 100, height: 40, content: text
  ed.highlight_current_line = highlight
  ed.cursor_pos = text.size
  s.repaint
  measure "highlight_current_line=#{highlight}", s, ed
end
