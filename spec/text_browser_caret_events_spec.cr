require "./spec_helper"

include Crysterm

# `Widget::TextBrowser`'s own caret moves — an anchor jump, link focus,
# a history step — report `Event::CursorPositionChanged` like any other
# programmatic move (`Mixin::TextEditing#cursor_position=`), so a widget
# following the caret (a current-line highlight, a paired editor) sees them.

private def new_tb(s)
  tb = Widget::TextBrowser.new parent: s, left: 0, top: 0, width: 40, height: 8
  s.repaint
  tb
end

describe "TextBrowser caret events" do
  it "reports the caret move of an anchor jump" do
    s = headless_screen(40, 8, default_quit_keys: true)
    tb = new_tb s
    tb.set_markdown "# Top\n\ntext\n\n## Deep\n\nmore"
    moves = [] of Int32
    tb.on(Crysterm::Event::CursorPositionChanged) { |e| moves << e.position }
    tb.goto_anchor("#deep").should be_true
    moves.should eq [tb.cursor_position]
    tb.cursor_position.should be > 0
    s.destroy
  end

  it "reports the caret move of focusing a link, and of a history step back" do
    s = headless_screen(40, 8, default_quit_keys: true)
    tb = new_tb s
    tb.set_markdown "# Top\n\ngo [one](#deep)\n\n## Deep\n\nmore"
    tb.source = "#top" # a current source, for the history step to return to
    moves = [] of Int32
    tb.on(Crysterm::Event::CursorPositionChanged) { |e| moves << e.position }
    tb.focus_next_link.should be_true
    moves.size.should eq 1
    tb.activate_link "#deep"
    moves.size.should eq 2
    tb.backward.should be_true
    moves.size.should eq 3
    moves.last.should eq moves.first
    s.destroy
  end

  it "puts the heading an anchor jump lands on at the top of the viewport" do
    s = headless_screen(40, 8, default_quit_keys: true)
    tb = new_tb s
    before = (1..30).map { |i| "Before #{i}" }.join("\n\n")
    after = (1..30).map { |i| "After #{i}" }.join("\n\n")
    tb.set_markdown "# Top\n\n#{before}\n\n## Deep\n\n#{after}\n"
    s.repaint
    tb.goto_anchor("#deep").should be_true
    s.repaint
    tb.scroll_position.should eq tb.cursor_row
    tb.scroll_position.should be > 0
    # Scrolled past it and jumped again: back at the top row.
    tb.scroll_to tb.cursor_row + 3
    tb.goto_anchor("#deep").should be_true
    tb.scroll_position.should eq tb.cursor_row
    s.destroy
  end

  it "jumps back to the current location's anchor when it is followed again, without a history step" do
    s = headless_screen(40, 8, default_quit_keys: true)
    tb = new_tb s
    tb.set_markdown "# Top\n\ntext\n\n## Deep\n\nmore"
    tb.source = "#top"
    tb.source = "#deep"
    at_deep = tb.cursor_position
    at_deep.should be > 0
    tb.cursor_position = 0 # the reader moved on
    tb.source = "#deep"
    tb.cursor_position.should eq at_deep
    tb.backward.should be_true # one step: back to "#top", not to "#deep" again
    tb.backward.should be_false
    s.destroy
  end
end
