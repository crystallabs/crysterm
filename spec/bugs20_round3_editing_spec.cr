require "./spec_helper"

include Crysterm

private PARAGRAPHS = (1..40).map { |i| "Line #{i}" }.join("\n\n")
private LINES      = (1..40).map { |i| "line #{i}" }.join("\n")

private def rich_view(s) : Widget::TextEdit
  te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 30, height: 8
  te.set_markdown PARAGRAPHS
  s.repaint
  te
end

# The bottom-most scroll position of *w* as laid out.
private def scroll_end(w) : Int32
  w.scroll 1000
  w.scroll_position
end

describe "TextEdit and changes it did not make" do
  it "leaves a reader who scrolled up where they are while a stream appends" do
    s = headless_screen(30, 8)
    te = rich_view s
    te.follow_tail = true
    te.cursor_position = te.document.size
    bottom = scroll_end te
    bottom.should be > 5
    te.scroll -5
    s.repaint
    te.scroll_position.should eq bottom - 5
    3.times do |i|
      te.append_markdown "more #{i}\n\n"
      s.repaint
      te.scroll_position.should eq bottom - 5
    end
  end

  it "follows the end again once scrolled back to it" do
    s = headless_screen(30, 8)
    te = rich_view s
    te.follow_tail = true
    bottom = scroll_end te
    te.scroll -5
    s.repaint
    te.append_markdown "more a\n\n"
    s.repaint
    te.scroll_position.should eq bottom - 5
    grown = scroll_end te
    grown.should be > bottom
    s.repaint
    te.append_markdown "more b\n\n"
    s.repaint
    te.scroll_position.should be > grown
    te.scroll_position.should eq scroll_end(te)
  end

  it "follows the end, not a caret in the middle of the document" do
    s = headless_screen(30, 8)
    te = rich_view s
    te.follow_tail = true
    te.cursor_position = te.document.block_position(te.document.block_count // 2)
    bottom = scroll_end te
    s.repaint
    te.append_markdown "more\n\n"
    s.repaint
    te.scroll_position.should be > bottom
  end

  it "does not move without follow_tail" do
    s = headless_screen(30, 8)
    te = rich_view s
    te.follow_tail?.should be_false
    te.cursor_position = te.document.size
    bottom = scroll_end te
    te.scroll -3
    s.repaint
    te.append_markdown "more\n\n"
    s.repaint
    te.scroll_position.should eq bottom - 3
    # At the end as well: nothing follows it.
    te.scroll 3
    s.repaint
    te.append_markdown "again\n\n"
    s.repaint
    te.scroll_position.should eq bottom
  end

  it "does not move for an edit made through another view or a cursor" do
    s = headless_screen(30, 16)
    te = rich_view s
    other = Widget::TextEdit.new parent: s, left: 0, top: 8, width: 30, height: 8, document: te.document
    s.repaint
    te.scroll 6
    s.repaint
    te.cursor_position.should eq 0
    other.cursor_position = other.document.size
    other.insert_text "typed elsewhere"
    s.repaint
    te.scroll_position.should eq 6
    te.document.cursor(te.document.size).insert_text "x"
    s.repaint
    te.scroll_position.should eq 6
  end

  it "brings the caret into view for its own edits" do
    s = headless_screen(30, 8)
    te = rich_view s
    te.follow_tail = true
    te.cursor_position.should eq 0
    scroll_end(te).should be > 0
    s.repaint
    te.insert_text "x"
    s.repaint
    te.scroll_position.should eq 0

    scroll_end te
    s.repaint
    te.undo.should be_true
    s.repaint
    te.scroll_position.should eq 0
  end

  it "rewinds to the top for its own whole-content setters" do
    s = headless_screen(30, 8)
    te = rich_view s
    scroll_end(te).should be > 0
    s.repaint
    te.set_tags PARAGRAPHS
    s.repaint
    te.scroll_position.should eq 0

    scroll_end te
    s.repaint
    te.set_content PARAGRAPHS
    s.repaint
    te.scroll_position.should eq 0
  end
end

describe "PlainTextEdit and changes it did not make" do
  it "keeps its scroll position, and follows the caret for its own" do
    s = headless_screen(30, 8)
    pte = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 30, height: 8, content: LINES
    pte.cursor_position = 0
    s.repaint
    pte.scroll 10
    s.repaint
    pte.scroll_position.should eq 10
    # One line patched in place, then a change the patch cannot take.
    pte.document.cursor(pte.document.size).insert_text "x"
    s.repaint
    pte.scroll_position.should eq 10
    pte.document.cursor(pte.document.size).insert_text "\ny\nz"
    s.repaint
    pte.scroll_position.should eq 10

    pte.insert_text "own"
    s.repaint
    pte.scroll_position.should eq 0
  end

  it "follows the end with follow_tail while it shows the end" do
    s = headless_screen(30, 8)
    pte = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 30, height: 8, content: LINES
    pte.follow_tail = true
    pte.cursor_position = 0
    s.repaint
    bottom = scroll_end pte
    s.repaint
    pte.document.cursor(pte.document.size).insert_text "\nnew 1\nnew 2"
    s.repaint
    pte.scroll_position.should eq bottom + 2
    pte.scroll -4
    s.repaint
    pte.document.cursor(pte.document.size).insert_text "\nnew 3"
    s.repaint
    pte.scroll_position.should eq bottom - 2
  end
end

describe "plain text and its paragraph separators" do
  it "takes U+2029 as a block break, as \\n, \\r\\n and a lone \\r" do
    doc = TextDocument.new("a b\r\nc\rd\ne")
    doc.blocks.map(&.text).should eq ["a", "b", "c", "d", "e"]
    doc.cursor(1).insert_text("1\u{2029}2")
    doc.to_plain_text.should eq "a1\n2\nb\nc\nd\ne"
    TextDocumentFragment.from_plain_text("x y").blocks.map(&.text).should eq ["x", "y"]
  end

  it "shows a PlainTextEdit value with them one row per block, the caret where the text is" do
    s = headless_screen(30, 8)
    pte = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 30, height: 8
    pte.value = "ab\rcd\r\nef gh"
    s.repaint
    pte.value.should eq "ab\ncd\nef\ngh"
    pte.document.block_count.should eq 4
    pte.wrapped_lines.lines.should eq ["ab", "cd", "ef", "gh"]
    pte.cursor_position.should eq 11
    pte.cursor_row.should eq 3
    # The start of the last row.
    pte.position_at(0, 3).should eq 9
    pte.position_at(1, 1).should eq 4
  end
end

describe "TextBlock#source_line through an undo" do
  it "comes back with the blocks a multi-block removal took" do
    doc = TextDocument.from_markdown("one\n\ntwo\n\nthree\n\nfour\n")
    stamps = doc.blocks.map(&.source_line)
    stamps.compact.size.should be >= 4
    # From inside the first block to inside the last.
    c = doc.cursor(1, doc.size - 1)
    c.remove_selected_text
    doc.block_count.should eq 1
    doc.undo.should be_true
    doc.blocks.map(&.source_line).should eq stamps
    doc.redo.should be_true
    doc.undo.should be_true
    doc.blocks.map(&.source_line).should eq stamps
  end

  it "comes back when the removal began at a block's start" do
    doc = TextDocument.from_markdown("one\n\ntwo\n\nthree\n\nfour\n")
    stamps = doc.blocks.map(&.source_line)
    c = doc.cursor(0, doc.size)
    c.remove_selected_text
    doc.undo.should be_true
    doc.blocks.map(&.source_line).should eq stamps
  end

  it "is not carried by a copy pasted elsewhere" do
    doc = TextDocument.from_markdown("one\n\ntwo\n\nthree\n\nfour\n")
    stamps = doc.blocks.compact_map(&.source_line)
    frag = doc.cursor(0, doc.size).selection
    doc.cursor(doc.size).insert_fragment frag
    doc.blocks.compact_map(&.source_line).should eq stamps
    # The stamped block keeps its stamp with a copy pasted at its start.
    doc.cursor(0).insert_fragment frag
    doc.blocks.compact_map(&.source_line).should eq stamps
    doc.blocks[0].source_line.should eq stamps[0]
    doc.undo.should be_true
    doc.blocks[0].source_line.should eq stamps[0]
  end

  it "stays with the head of a block cut in the middle" do
    b = TextBlock.new("hello")
    b.source_line = 7
    b.slice(0, 3).source_line.should eq 7
    b.slice(2, 5).source_line.should be_nil
  end
end
