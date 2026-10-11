require "./spec_helper"

include Crysterm

# `Widget::PlainTextEdit` patches one wrapped logical line per single-block
# edit (`Widget#replace_content_line`) instead of pushing the whole document
# back through `set_content`. Every patched state must be byte-identical, in
# every `CLines` field and in the raw/printable content, to a fresh editor
# given the same full text.

private W = 24
private H =  4

private def new_editor(text, wrap = true, height = H)
  s = headless_screen(60, 20)
  pte = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: W, height: height,
    wrap_content: wrap, content: text
  s.repaint
  {s, pte}
end

# A fresh editor over *pte*'s current document text, laid out from scratch
# (at the same horizontal scroll, which unwrapped rows are sliced by).
private def reference_for(pte, wrap, height)
  s = headless_screen(60, 20)
  ref = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: W, height: height,
    wrap_content: wrap, content: pte.value
  ref.child_base_x = pte.child_base_x
  s.repaint
  ref
end

private def expect_identical(pte, wrap = true, height = H)
  ref = reference_for(pte, wrap, height)
  pc = pte.wrapped_lines
  rc = ref.wrapped_lines
  pc.lines.should eq rc.lines
  pc.fake.should eq rc.fake
  pc.ftor.should eq rc.ftor
  pc.rtof.should eq rc.rtof
  pc.attr.should eq rc.attr
  pc.max_width.should eq rc.max_width
  pc.full_width.should eq rc.full_width
  pte.content.should eq ref.content
  pte.pcontent.should eq ref.pcontent
  pte.rendered_content.should eq ref.rendered_content
end

# Document position of column *col* in logical line *line*.
private def at(pte, line, col)
  pte.document.block_position(line) + col
end

# Types *str* at *pos*, then shows the frame. The patch leaves the raw
# content to be re-joined lazily, so a stale `@content` right after the
# edit is the sign the fast path (not a full `set_content`) handled it.
private def type_at(pte, s, pos, str, *, fast = true)
  pte.cursor_pos = pos
  pte.insert_text str
  pte.@_content_stale.should be_true if fast
  s.repaint
end

private def backspace_at(pte, s, pos, n = 1, *, fast = true)
  pte.cursor_pos = pos
  n.times { pte._listener kp('\0', ::Tput::Key::Backspace) }
  pte.@_content_stale.should be_true if fast
  s.repaint
end

private TEXT = "first line here\nsecond, somewhat longer line of text\nthird\n\nfifth and last"

describe "Widget::PlainTextEdit single-line display patch" do
  it "inserts in the middle of a line" do
    s, pte = new_editor TEXT
    type_at pte, s, at(pte, 1, 8), "X"
    pte.value.should eq TEXT.sub("second, ", "second, X")
    expect_identical pte
  end

  it "deletes from a line" do
    s, pte = new_editor TEXT
    backspace_at pte, s, at(pte, 1, 8), 3
    pte.value.should eq TEXT.sub("second, ", "secon")
    expect_identical pte
  end

  it "grows a line past the wrap width so it gains rows" do
    s, pte = new_editor TEXT
    rows = pte.wrapped_lines.ftor[2].size
    type_at pte, s, at(pte, 2, 5), " plus a long tail that wraps around twice over"
    pte.wrapped_lines.ftor[2].size.should be > rows
    expect_identical pte
  end

  it "shrinks a wrapped line so it loses rows" do
    s, pte = new_editor TEXT
    rows = pte.wrapped_lines.ftor[1].size
    rows.should be > 1
    backspace_at pte, s, at(pte, 1, 36), 20
    pte.wrapped_lines.ftor[1].size.should be < rows
    expect_identical pte
  end

  it "edits the first and the last line" do
    s, pte = new_editor TEXT
    type_at pte, s, at(pte, 0, 0), ">> "
    expect_identical pte
    type_at pte, s, at(pte, 4, 14), " <<"
    expect_identical pte
    backspace_at pte, s, at(pte, 0, 3), 3
    expect_identical pte
  end

  it "handles tab characters (fake lines are tab-expanded, raw lines are not)" do
    s, pte = new_editor TEXT
    type_at pte, s, at(pte, 2, 0), "\t"
    pte.value.should start_with "first line here\nsecond, somewhat longer line of text\n\tthird"
    expect_identical pte
    type_at pte, s, at(pte, 2, 3), "\t\t"
    expect_identical pte
    backspace_at pte, s, at(pte, 2, 1)
    expect_identical pte
  end

  it "empties a line and refills it" do
    s, pte = new_editor TEXT
    backspace_at pte, s, at(pte, 2, 5), 5
    pte.wrapped_lines.fake[2].should eq ""
    expect_identical pte
    type_at pte, s, at(pte, 2, 0), "again"
    expect_identical pte
    type_at pte, s, at(pte, 3, 0), "no longer empty"
    expect_identical pte
  end

  it "replaces the widest line (wrapped: max_width; unwrapped: full_width)" do
    s, pte = new_editor TEXT
    backspace_at pte, s, at(pte, 1, 36), 30
    expect_identical pte

    s, pte = new_editor TEXT, false
    pte.wrapped_lines.full_width.should eq 36
    backspace_at pte, s, at(pte, 1, 36), 30
    pte.wrapped_lines.full_width.should eq 15
    expect_identical pte, false
    type_at pte, s, at(pte, 3, 0), "the new widest line of them all"
    pte.wrapped_lines.full_width.should eq 31
    expect_identical pte, false
  end

  it "reconciles an AsNeeded scrollbar flip with a full reparse" do
    s, pte = new_editor "a\nb\nc", true, 8
    # The editor's own caret column is always reserved; the bar adds to it.
    m0 = pte.content_margin_x
    # Grows past the viewport: the bar appears and every line is re-wrapped
    # at the narrower width, exactly as a fresh layout would.
    tail = " and then some more words to wrap over several rows" * 3
    type_at pte, s, at(pte, 1, 1), tail, fast: false
    pte.content_margin_x.should be > m0
    expect_identical pte, true, 8
    # And back off again.
    backspace_at pte, s, at(pte, 1, 1 + tail.size), tail.size, fast: false
    pte.content_margin_x.should eq m0
    expect_identical pte, true, 8
  end

  it "falls back to the full push for edits that span lines" do
    s, pte = new_editor TEXT
    type_at pte, s, at(pte, 2, 2), "x\ny", fast: false
    pte.value.should eq TEXT.sub("third", "thx\nyird")
    expect_identical pte
    # Joining two lines (backspace over a newline).
    backspace_at pte, s, at(pte, 3, 0), fast: false
    pte.value.should eq TEXT.sub("third", "thxyird")
    expect_identical pte
  end

  it "keeps the raw content and the wrapped lines in step across edit kinds" do
    s, pte = new_editor TEXT
    type_at pte, s, at(pte, 0, 5), "!"
    type_at pte, s, at(pte, 3, 0), "x\ny", fast: false
    type_at pte, s, at(pte, 4, 1), "?"
    pte.content.should eq pte.value
    expect_identical pte
    pte.value = "fresh\ntext"
    s.repaint
    type_at pte, s, at(pte, 1, 4), "ure"
    pte.value.should eq "fresh\ntexture"
    expect_identical pte
  end

  it "matches a fresh layout after many random single-line edits" do
    s, pte = new_editor TEXT
    rng = Random.new(42)
    120.times do |i|
      line = rng.rand(pte.document.block_count)
      len = pte.document.blocks[line].size
      col = rng.rand(len + 1)
      if rng.rand(3) == 0 && col > 0
        backspace_at pte, s, at(pte, line, col), 1, fast: false
      else
        type_at pte, s, at(pte, line, col), ["a", "bb", "ccc", "dddd", "_", "\t"].sample(rng), fast: false
      end
      expect_identical pte if i % 30 == 29
    end
    expect_identical pte
  end
end
