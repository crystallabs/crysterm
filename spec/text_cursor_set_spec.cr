require "./spec_helper"

include Crysterm

# `#text_cursor=` (Qt `setTextCursor`) on the document-backed views: the
# view scrolls to keep the adopted caret on window and reports the move
# through `Event::CursorPositionChanged`, so another widget can place a
# view's caret the way a keystroke would — for both `TextEdit` (whose row
# layout is rebuilt at paint time and must be refreshed for a caret set
# right after a document swap) and `PlainTextEdit`.

private def long_markdown : String
  (1..40).map { |i| "Line #{i}" }.join("\n\n") + "\n"
end

describe "text_cursor=" do
  it "scrolls a TextBrowser to a caret set right after the document was replaced" do
    s = headless_screen(40, 8, default_quit_keys: true)
    tb = Widget::TextBrowser.new parent: s, left: 0, top: 0, width: 40, height: 8
    tb.set_markdown "short"
    s.repaint
    moves = [] of Int32
    tb.on(Event::CursorPositionChanged) { |e| moves << e.position }

    tb.set_markdown long_markdown
    target = tb.document.block_position(30)
    tb.text_cursor = TextCursor.new(tb.document, target)

    tb.cursor_position.should eq target
    moves.should eq [target]
    s.repaint
    tb.scroll_position.should be > 0
    s.dump.to_s.should contain "Line 31"
  end

  it "scrolls a PlainTextEdit to the adopted caret and reports it once" do
    s = headless_screen(40, 8, default_quit_keys: true)
    pe = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 40, height: 8
    pe.plain_text = (1..40).map { |i| "line #{i}" }.join("\n")
    s.repaint
    moves = [] of Int32
    pe.on(Event::CursorPositionChanged) { |e| moves << e.position }

    target = pe.document.block_position(25)
    pe.text_cursor = TextCursor.new(pe.document, target)
    pe.cursor_position.should eq target
    moves.should eq [target]
    s.repaint
    pe.scroll_position.should be > 0
    s.dump.to_s.should contain "line 26"

    # Setting the same position again is not a move.
    pe.text_cursor = TextCursor.new(pe.document, target)
    moves.size.should eq 1
  end
end
