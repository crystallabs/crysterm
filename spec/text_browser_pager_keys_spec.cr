require "./spec_helper"

include Crysterm

private TEXT = (1..60).map { |i| "line #{i}" }.join("\n")

private def press(c : Char) : Event::KeyPress
  Event::KeyPress.new c
end

private def press(k : Tput::Key) : Event::KeyPress
  Event::KeyPress.new '\0', k
end

describe "TextBrowser pager keys" do
  it "pages forward like PageDown while read-only" do
    s = headless_screen(30, 10)
    by_space = Widget::TextBrowser.new parent: s, left: 0, top: 0, width: 30, height: 10
    by_space.value = TEXT
    by_space.cursor_pos = 0
    by_space.focus
    s.repaint
    # Each press turns the view a page, as PageDown does — the contract the
    # key maps onto.
    2.times { by_space._listener press(' ') }
    s.repaint
    by_space.scroll_position.should be > 0
    pos_after_space = by_space.scroll_position

    by_page = Widget::TextBrowser.new parent: s, left: 0, top: 0, width: 30, height: 10
    by_page.value = TEXT
    by_page.cursor_pos = 0
    by_page.focus
    s.repaint
    2.times { by_page._listener press(Tput::Key::PageDown) }
    s.repaint
    by_page.scroll_position.should eq pos_after_space
    by_space.value.should eq TEXT # nothing typed
  end

  it "moves down a line on Enter with no link focused, and follows a focused link" do
    s = headless_screen(30, 10)
    tb = Widget::TextBrowser.new parent: s, left: 0, top: 0, width: 30, height: 10
    tb.value = TEXT
    tb.cursor_pos = 0
    tb.focus
    s.repaint
    tb._listener press(Tput::Key::Enter)
    tb.cursor_pos.should eq TEXT.index!("line 2")
    tb.value.should eq TEXT
    12.times { tb._listener press(Tput::Key::Enter) }
    s.repaint
    tb.scroll_position.should be > 0

    linked = Widget::TextBrowser.new parent: s, left: 0, top: 0, width: 30, height: 10
    linked.set_markdown "see [two](#two)\n\n## One\n\ntext\n\n## Two\n\nend"
    linked.focus
    s.repaint
    linked.focus_link 1
    linked._listener press(Tput::Key::Enter)
    s.repaint
    linked.document.plain_text[linked.cursor_pos..].should start_with "Two"
  end

  it "types a space when the browser is writable" do
    s = headless_screen(30, 10)
    tb = Widget::TextBrowser.new parent: s, left: 0, top: 0, width: 30, height: 10, read_only: false
    tb.value = "ab"
    tb.cursor_pos = 1
    tb.focus
    s.repaint
    tb._listener press(' ')
    tb.value.should eq "a b"
  end
end
