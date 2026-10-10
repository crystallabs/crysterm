require "./spec_helper"

include Crysterm

# 50 equally long lines ("line 01".."line 50"), so that row r at column 0 is
# buffer position r * 8.
private TEXT = (1..50).map { |i| "line #{i.to_s.rjust(2, '0')}" }.join("\n")
private ROW  = 8

private def press(te, key : Tput::Key)
  te._listener Crysterm::Event::KeyPress.new('\0', key)
end

# Page Up/Down turn the *viewport* by a page and put the caret on the first
# (Page Down) / last (Page Up) row of the new page, as in vi and less. The
# previous behavior moved the caret by a page and let the view follow, so the
# first press parked the caret at the bottom row without scrolling.
{% for klass in [Widget::PlainTextEdit, Widget::TextEdit] %}
  describe "{{ klass }} Page Up/Down" do
    it "scrolls a page on the first press and puts the caret on the new page's first/last row" do
      s = headless_screen(30, 10)
      te = {{ klass }}.new parent: s, left: 0, top: 0, width: 30, height: 10
      te.value = TEXT
      s.repaint
      te.cursor_pos = 0
      te.scroll_to 0
      s.repaint
      te.scroll_position.should eq 0
      page = 9 # 10 visible rows, one of overlap

      press te, Tput::Key::PageDown
      te.scroll_position.should eq page       # the view turned a page at once
      te.cursor_pos.should eq page * ROW      # caret on the first row of it

      press te, Tput::Key::PageDown
      te.scroll_position.should eq 2 * page
      te.cursor_pos.should eq 2 * page * ROW

      press te, Tput::Key::PageUp
      te.scroll_position.should eq page
      te.cursor_pos.should eq (page + 10 - 1) * ROW # caret on the last visible row

      press te, Tput::Key::PageUp
      te.scroll_position.should eq 0
      te.cursor_pos.should eq (10 - 1) * ROW
    end

    it "moves the caret to the first/last row when the view is already at that end" do
      s = headless_screen(30, 10)
      te = {{ klass }}.new parent: s, left: 0, top: 0, width: 30, height: 10
      te.value = TEXT
      s.repaint
      te.cursor_pos = 5 * ROW
      te.scroll_to 0
      s.repaint

      press te, Tput::Key::PageUp
      te.scroll_position.should eq 0
      te.cursor_pos.should eq 0

      te.scroll_to 10_000
      s.repaint
      te.scroll_position.should eq 40
      te.cursor_pos = 42 * ROW
      press te, Tput::Key::PageDown
      te.scroll_position.should eq 40
      te.cursor_pos.should eq 49 * ROW
    end

    it "keeps the goal column across pages" do
      s = headless_screen(30, 10)
      te = {{ klass }}.new parent: s, left: 0, top: 0, width: 30, height: 10
      te.value = TEXT
      s.repaint
      te.cursor_pos = 3 # "lin|e 01"
      te.scroll_to 0
      s.repaint

      press te, Tput::Key::PageDown
      te.cursor_pos.should eq 9 * ROW + 3
      press te, Tput::Key::PageUp
      te.cursor_pos.should eq 9 * ROW + 3
    end
  end
{% end %}

describe "Widget::TextBrowser Space" do
  it "reads on by a page from the first press" do
    s = headless_screen(30, 10)
    tb = Widget::TextBrowser.new parent: s, left: 0, top: 0, width: 30, height: 10
    tb.value = TEXT
    s.repaint
    tb.cursor_pos = 0
    tb.scroll_to 0
    s.repaint

    tb._listener Crysterm::Event::KeyPress.new(' ')
    tb.scroll_position.should eq 9
  end
end
