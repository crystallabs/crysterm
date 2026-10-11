require "./spec_helper"

include Crysterm

# `Mixin::TextEditing#highlight_current_line`: the caret's display row is
# tinted (`#current_line_format`, derived from the widget's background by
# default) at paint time, following the caret, without touching the
# widget's `#extra_selections`.

private def headless_window
  Window.new input: IO::Memory.new, output: IO::Memory.new, width: 40, height: 8
end

# Background of the cell at column *col* of *w*'s viewport row *row*.
private def bg_at(window, w, row, col = 0)
  Attr.bg(window.cell_rows[w.atop + row][w.aleft + col].attr)
end

private DOC = (1..5).map { |i| "line #{i}" }.join("\n")

describe "TextEditing#highlight_current_line" do
  it "tints the caret's row across the width, following the caret" do
    window = headless_window
    e = Widget::PlainTextEdit.new parent: window, left: 0, top: 0, width: 40, height: 8
    e.plain_text = DOC
    window.repaint
    plain = bg_at(window, e, 0)
    e.highlight_current_line?.should be_false

    e.highlight_current_line = true
    e.cursor_position = e.document.block_position(2)
    window.repaint
    bg_at(window, e, 2).should_not eq plain
    bg_at(window, e, 2, 38).should eq bg_at(window, e, 2)
    bg_at(window, e, 0).should eq plain
    e.extra_selections.should be_empty

    e.cursor_position = 0
    window.repaint
    bg_at(window, e, 0).should_not eq plain
    bg_at(window, e, 2).should eq plain

    e.highlight_current_line = false
    window.repaint
    bg_at(window, e, 0).should eq plain
    window.destroy
  end

  it "uses current_line_format when set, and the app's extra selections paint over it" do
    window = headless_window
    e = Widget::PlainTextEdit.new parent: window, left: 0, top: 0, width: 40, height: 8
    e.plain_text = DOC
    e.cursor_position = 0 # plain_text= leaves the caret at the end
    window.repaint
    plain = bg_at(window, e, 0)
    e.highlight_current_line = true
    window.repaint
    derived = bg_at(window, e, 0)
    derived.should_not eq plain

    e.current_line_format = TextCharFormat.new(bg: 0x204060)
    window.repaint
    custom = bg_at(window, e, 0)
    custom.should_not eq plain
    custom.should_not eq derived
    bg_at(window, e, 0, 38).should eq custom

    c = TextCursor.new(e.document, 0)
    c.set_position(4, :keep_anchor)
    e.extra_selections = [Widget::TextEdit::ExtraSelection.new(c, TextCharFormat.new(bg: 0x800000))]
    window.repaint
    bg_at(window, e, 0, 1).should_not eq custom
    bg_at(window, e, 0, 20).should eq custom
    window.destroy
  end

  it "works in a TextBrowser, next to its link highlight" do
    window = headless_window
    tb = Widget::TextBrowser.new parent: window, left: 0, top: 0, width: 40, height: 8
    tb.set_markdown "one\n\ntwo [link](#x)\n\nthree"
    window.repaint
    plain = bg_at(window, tb, 0)
    tb.highlight_current_line = true
    tb.cursor_position = tb.document.block_position(1)
    window.repaint
    row = tb.cursor_viewport_row
    bg_at(window, tb, row).should_not eq plain
    bg_at(window, tb, row + 1).should eq plain
    tb.focus_next_link.should be_true
    window.repaint
    tb.extra_selections.size.should eq 1
    bg_at(window, tb, tb.cursor_viewport_row).should_not eq plain
    window.destroy
  end
end
