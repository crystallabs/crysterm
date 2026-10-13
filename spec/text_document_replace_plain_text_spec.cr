require "./spec_helper"

include Crysterm

# `TextDocument#replace_plain_text`: the text replaced by an edit of only
# what differs, as one undo step (Qt Creator's diff-applying reload), not
# by `set_plain_text`'s reset — the history kept, cursors and the views'
# carets moving with the change as for any edit.

private def lines(range) : String
  range.map { |i| "line #{i}" }.join('\n')
end

describe "TextDocument#replace_plain_text" do
  it "makes the new text, and an unchanged text no step" do
    doc = TextDocument.new("alpha\nbeta\ngamma")
    doc.replace_plain_text("alpha\nbeta\ngamma").should be_false
    doc.undo_available?.should be_false
    doc.replace_plain_text("alpha\nBETA\ngamma\ndelta").should be_true
    doc.to_plain_text.should eq "alpha\nBETA\ngamma\ndelta"
  end

  it "is one undo step on top of the history, which it keeps" do
    doc = TextDocument.new("one\ntwo\nthree")
    doc.cursor(3).insert_text "!"
    doc.replace_plain_text("zero\none\nthree\nfour")
    doc.to_plain_text.should eq "zero\none\nthree\nfour"
    doc.undo.should be_true
    doc.to_plain_text.should eq "one!\ntwo\nthree"
    doc.undo.should be_true
    doc.to_plain_text.should eq "one\ntwo\nthree"
    doc.redo
    doc.redo
    doc.to_plain_text.should eq "zero\none\nthree\nfour"
  end

  it "joins an edit block already open" do
    doc = TextDocument.new("a\nb")
    doc.edit do
      doc.cursor(0).insert_text "x"
      doc.replace_plain_text("xa\nc")
    end
    doc.undo
    doc.to_plain_text.should eq "a\nb"
  end

  it "keeps cursors away from the changes where they were in the text" do
    old = lines(1..40)
    doc = TextDocument.new(old)
    # On "line 20" and "line 35".
    c20 = doc.cursor(old.index!("line 20") + 2)
    sel = doc.cursor(old.index!("line 35"), old.index!("line 35") + 7)
    changed = lines(1..40)
      .sub("line 3\n", "line 3\ninserted a\ninserted b\n")
      .sub("line 27", "line twenty-seven")
      .sub("line 38\n", "")
    doc.replace_plain_text(changed)
    doc.to_plain_text.should eq changed
    c20.position.should eq changed.index!("line 20") + 2
    sel.anchor.should eq changed.index!("line 35")
    sel.position.should eq changed.index!("line 35") + 7
  end

  it "changes only the characters that differ in a changed line" do
    doc = TextDocument.new("the quick fox\nend")
    before = doc.cursor(2) # in "the"
    after = doc.cursor(13) # the line's end
    doc.replace_plain_text("the slow fox\nend")
    before.position.should eq 2
    after.position.should eq 12
  end

  it "keeps a cursor at a change's start or end there, and moves one inside it to its start" do
    doc = TextDocument.new("aaa\nbbb\nccc")
    start = doc.cursor(4)
    inside = doc.cursor(5)
    finish = doc.cursor(7)
    doc.replace_plain_text("aaa\nwxyz\nccc")
    start.position.should eq 4
    inside.position.should eq 4
    finish.position.should eq 8
  end

  it "handles changes at the start and the end, and to or from nothing" do
    doc = TextDocument.new("")
    doc.replace_plain_text("x\ny")
    doc.to_plain_text.should eq "x\ny"
    doc.replace_plain_text("w\nx\ny\nz\n")
    doc.to_plain_text.should eq "w\nx\ny\nz\n"
    doc.replace_plain_text("x")
    doc.to_plain_text.should eq "x"
    doc.replace_plain_text("")
    doc.to_plain_text.should eq ""
    doc.undo
    doc.to_plain_text.should eq "x"
  end

  it "turns any text into any other" do
    rng = Random.new(42)
    words = ["a", "b", "c", "dd", "é", ""]
    200.times do
      from = Array.new(rng.rand(0..12)) { words.sample(rng) }.join('\n')
      to = Array.new(rng.rand(0..12)) { words.sample(rng) }.join('\n')
      doc = TextDocument.new(from)
      doc.replace_plain_text(to)
      doc.to_plain_text.should eq to
      doc.undo if from != to
      doc.to_plain_text.should eq from
    end
  end

  it "falls back to one change for a difference too large to search" do
    old = (1..3000).map { |i| "old #{i}" }.join('\n')
    new = (1..3000).map { |i| "new #{i}" }.join('\n')
    doc = TextDocument.new(old)
    doc.replace_plain_text(new)
    doc.to_plain_text.should eq new
    doc.undo
    doc.to_plain_text.should eq old
  end

  it "is modified after it, and a reload marks it clean there: an undo makes it modified again" do
    doc = TextDocument.new("one\ntwo")
    doc.modified?.should be_false
    doc.replace_plain_text("one\n2")
    doc.modified?.should be_true
    doc.modified = false
    doc.modified?.should be_false
    doc.undo
    doc.modified?.should be_true
    doc.redo
    doc.modified?.should be_false
  end

  it "leaves the formats of the text it does not change" do
    doc = TextDocument.new("bold\nplain")
    bold = TextCharFormat.new(bold: true)
    doc.cursor(0, 4).set_char_format(bold)
    doc.replace_plain_text("bold\nchanged")
    doc.char_format_of(1).try(&.bold?).should be_true
  end

  it "moves the carets and selections of the views on the document with it" do
    s = headless_screen(40, 6)
    doc = TextDocument.new(lines(1..10))
    a = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 40, height: 3, document: doc
    b = Widget::PlainTextEdit.new parent: s, left: 0, top: 3, width: 40, height: 3, document: doc
    s.repaint
    text = lines(1..10)
    a.cursor_position = text.index!("line 8") + 3
    b.set_caret text.index!("line 9") + 4, text.index!("line 9")
    changed = "header\n" + text.sub("line 5", "line five")
    doc.replace_plain_text(changed)
    a.cursor_position.should eq changed.index!("line 8") + 3
    b.selection_range.should eq changed.index!("line 9")...(changed.index!("line 9") + 4)
    s.repaint
    a.value.should eq changed
  end
end
