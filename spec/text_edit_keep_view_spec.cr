require "./spec_helper"

include Crysterm

private LONG = (1..40).map { |i| "Line #{i}" }.join("\n\n")

# `TextEdit#set_markdown`/`#set_html` with `keep_view`: a live preview
# re-rendered from its source keeps the reader's caret and scroll instead of
# rewinding to the top.
describe "TextEdit#set_markdown keep_view" do
  it "rewinds caret and scroll by default" do
    s = headless_screen(30, 8)
    te = Widget::TextBrowser.new parent: s, left: 0, top: 0, width: 30, height: 8
    te.set_markdown LONG
    te.cursor_position = te.document.size - 1
    s.repaint # scrolls to the caret, at the end
    te.scroll_position.should be > 0
    moves = [] of Int32
    te.on(Event::CursorPositionChanged) { |e| moves << e.position }
    te.set_markdown LONG + "\n\nmore"
    te.cursor_position.should eq 0
    moves.should eq [0] # the rewind is reported (Qt's setContent does too)
    s.repaint           # the view follows the caret back to the top
    te.scroll_position.should eq 0
    te.set_html "<p>a</p>"
    moves.should eq [0] # already at the start: nothing to report
  end

  it "keeps the caret and the scroll position across a re-render" do
    s = headless_screen(30, 8)
    te = Widget::TextBrowser.new parent: s, left: 0, top: 0, width: 30, height: 8
    te.set_markdown LONG
    # A caret in the middle of the document, scrolled into view.
    pos = te.document.block_position(te.document.block_count // 2)
    te.cursor_position = pos
    s.repaint
    offset = te.scroll_position
    offset.should be > 0
    moves = [] of Int32
    te.on(Event::CursorPositionChanged) { |e| moves << e.position }
    te.set_markdown LONG + "\n\nmore", keep_view: true
    te.cursor_position.should eq pos
    te.scroll_position.should eq offset
    s.repaint # the caret is still in view: nothing to scroll
    te.scroll_position.should eq offset
    te.document.plain_text.should end_with "more"
    moves.should be_empty # the caret did not move
    # Kept, but clamped: content shorter than the view scrolls back to the top.
    te.set_html "<p>a</p><p>b</p>", keep_view: true
    s.repaint
    te.scroll_position.should eq 0
  end

  it "clamps a kept caret to shorter content and reports the move" do
    s = headless_screen(30, 8)
    te = Widget::TextBrowser.new parent: s, left: 0, top: 0, width: 30, height: 8
    te.set_markdown LONG
    te.cursor_position = 100
    moves = [] of Int32
    te.on(Event::CursorPositionChanged) { |e| moves << e.position }
    te.set_markdown "short", keep_view: true
    te.cursor_position.should eq 5
    moves.should eq [5]
  end
end
