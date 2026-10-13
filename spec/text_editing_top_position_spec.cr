require "./spec_helper"

include Crysterm

# `Mixin::TextEditing#top_position` (the buffer position at the start of the
# first visible row) and `#scroll_position_to_row` (scroll so the row holding
# a position is on a chosen viewport row): what a view mirroring another's
# scroll on the same text, at another width, needs.

# Soft-wrapped long lines: at width 20 each takes three or more rows.
private TEXT = (1..30).map { |i| "L#{i} aaaa bbbb cccc dddd eeee ffff gggg hhhh" }.join("\n")

{% for kind in %w[PlainTextEdit TextEdit] %}
  describe "TextEditing#top_position ({{ kind.id }})" do
    it "is the first visible row's start after a scroll" do
      s = headless_screen(60, 8)
      e = Widget::{{ kind.id }}.new parent: s, top: 0, height: 8, left: 0, width: 20
      e.document.plain_text = TEXT
      s.repaint
      e.top_position.should eq 0

      e.scroll_to 7
      s.repaint
      e.scroll_position.should eq 7
      top = e.top_position
      top.should be > 0
      # What the top row shows is the text that starts there.
      shown = row_text(s, 0, 0..19).delete("░▓█│").strip
      shown.should_not be_empty
      e.document.to_plain_text[top, shown.size].should eq shown
      # Scrolling a position to row 0 is a no-op from there.
      e.scroll_position_to_row top
      s.repaint
      e.scroll_position.should eq 7
      s.destroy
    end

    it "lets a view of another width show the same first row" do
      s = headless_screen(60, 8)
      a = Widget::{{ kind.id }}.new parent: s, top: 0, height: 8, left: 0, width: 20
      b = Widget::{{ kind.id }}.new parent: s, top: 0, height: 8, left: 20, width: 40
      a.document.plain_text = TEXT
      b.document.plain_text = TEXT
      s.repaint
      b.cursor_position = 0

      a.scroll_to 11
      s.repaint
      b.scroll_position_to_row a.top_position
      s.repaint
      # b's top row holds a's top position, so its top is at or before it,
      # on the same logical line.
      b.top_position.should be <= a.top_position
      line = TEXT[0, a.top_position].count('\n')
      TEXT[0, b.top_position].count('\n').should eq line
      b.scroll_position.should be < a.scroll_position
      # The caret stays where it was.
      b.cursor_position.should eq 0
      s.destroy
    end

    it "puts the position on the given viewport row, as far as the content allows" do
      s = headless_screen(60, 8)
      e = Widget::{{ kind.id }}.new parent: s, top: 0, height: 8, left: 0, width: 20
      e.document.plain_text = TEXT
      s.repaint
      e.scroll_to 20
      s.repaint
      pos = e.top_position
      e.scroll_to 0
      s.repaint
      e.scroll_position_to_row pos, 3
      s.repaint
      e.scroll_position.should eq 17

      e.scroll_position_to_row 0, 5
      s.repaint
      e.scroll_position.should eq 0
      s.destroy
    end
  end
{% end %}
