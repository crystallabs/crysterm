require "./spec_helper"

include Crysterm

# A destroyed document-backed view leaves its document
# (`DocumentBuffer#leave_document`): the `ContentsChanged` handler it put on
# the document goes with it, so a document shared with another view, or
# kept by the application, stops calling into the dead widget.

private def contents_handlers(doc : TextDocument) : Int32
  doc.handlers(Crysterm::Event::ContentsChanged).size
end

describe "DocumentBuffer on destroy" do
  it "drops a destroyed PlainTextEdit's handler from the shared document" do
    sa = headless_screen(40, 6, default_quit_keys: true)
    sb = headless_screen(40, 6, default_quit_keys: true)
    doc = TextDocument.new("hello world")
    base = contents_handlers(doc)
    a = Widget::PlainTextEdit.new parent: sa, left: 0, top: 0, width: 40, height: 4, document: doc
    b = Widget::PlainTextEdit.new parent: sb, left: 0, top: 0, width: 40, height: 4, document: doc
    sa.repaint
    sb.repaint
    contents_handlers(doc).should eq base + 2

    b.cursor_pos = 6
    b.destroy
    sb.destroy
    contents_handlers(doc).should eq base + 1

    # Edits through the surviving view and through a bare cursor neither
    # raise nor reach the destroyed view (its caret is not shifted).
    a.cursor_pos = 0
    a._listener kp('X')
    doc.cursor(0).insert_text(">>")
    doc.to_plain_text.should eq ">>Xhello world"
    a.cursor_pos.should eq 3
    b.cursor_pos.should eq 6
    a.undo.should be_true
    a.redo.should be_true
  end

  it "drops a destroyed TextEdit's handler, also when its window goes" do
    s = headless_screen(40, 6, default_quit_keys: true)
    doc = TextDocument.new("hello")
    base = contents_handlers(doc)
    te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 40, height: 4, document: doc
    s.repaint
    contents_handlers(doc).should eq base + 1
    s.destroy
    contents_handlers(doc).should eq base
    te.cursor_pos.should eq 0 # where a view adopting a document starts (Qt setDocument)
    doc.cursor(0).insert_text("oh, ")
    te.cursor_pos.should eq 0 # a live view's caret would be pushed to 4
    doc.to_plain_text.should eq "oh, hello"
  end

  it "keeps the handlers of a view that is not destroyed" do
    s = headless_screen(40, 6, default_quit_keys: true)
    doc = TextDocument.new("x")
    base = contents_handlers(doc)
    a = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 40, height: 4, document: doc
    Widget::PlainTextEdit.new(parent: s, left: 0, top: 4, width: 40, height: 2, document: doc).destroy
    contents_handlers(doc).should eq base + 1
    a.cursor_pos = 0
    doc.cursor(0).insert_text("y")
    a.cursor_pos.should eq 1
  end

  it "does not subscribe a destroyed view to a document given to it afterwards" do
    s = headless_screen(40, 6, default_quit_keys: true)
    doc = TextDocument.new("x")
    base = contents_handlers(doc)
    a = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 40, height: 4
    t = Widget::TextEdit.new parent: s, left: 0, top: 4, width: 40, height: 2
    s.destroy
    a.document = doc
    t.document = doc
    contents_handlers(doc).should eq base
    doc.cursor(0).insert_text("y")
    a.cursor_pos.should eq 0
  end
end
