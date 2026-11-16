require "../src/crysterm"

# `SyntaxHighlighter#rehighlight` over a 10,000-line document shown in a
# `PlainTextEdit`: every block gets an overlay and a block state, each of
# which is an overlay change the document tells its views of.
#
# Reports a full rehighlight that changes every block (the highlighter flips
# between two colorings), and the `ContentsChanged` events one such pass
# emits.
#
# Run:  crystal run --release benchmarks/highlighter-rehighlight.cr

private class BenchFlipHighlighter < Crysterm::SyntaxHighlighter
  property flip = false

  def highlight_block(text : String)
    set_format(0, 4, @flip ? "red" : "blue")
    if i = text.index("fox")
      set_format(i, 3, Crysterm::TextCharFormat.new(bold: true))
    end
    self.current_block_state = @flip ? 1 : 0
  end
end

LINES = 10_000

s = Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
  width: 100, height: 30, optimization: Crysterm::OptimizationFlag::None)
text = String.build do |io|
  LINES.times do |i|
    io << '\n' if i > 0
    io << "line " << i << ": the quick brown fox jumps over the lazy dog"
  end
end
edit = Crysterm::Widget::PlainTextEdit.new(parent: s, top: 0, left: 0, width: 80, height: 25, content: text)
s.repaint
doc = edit.document
hl = BenchFlipHighlighter.new(doc)
s.repaint

events = 0
doc.on(Crysterm::Event::ContentsChanged) { events += 1 }

rounds = 20
hl.flip = !hl.flip
hl.rehighlight # warm
events = 0
GC.collect
b0 = GC.stats.total_bytes
t0 = Time.instant
rounds.times do
  hl.flip = !hl.flip
  hl.rehighlight
end
dt = Time.instant - t0
db = GC.stats.total_bytes - b0
STDERR.printf "rehighlight of %d lines (every block changes): %8.2f ms  %8.1f KiB alloc  %d ContentsChanged per pass\n",
  LINES, dt.total_milliseconds / rounds, db.to_f / rounds / 1024, events // rounds

t0 = Time.instant
rounds.times do
  hl.flip = !hl.flip
  hl.rehighlight
  s.repaint
end
dt = Time.instant - t0
STDERR.printf "rehighlight + repaint:                            %8.2f ms\n", dt.total_milliseconds / rounds
