require "./spec_helper"

include Crysterm

# `Widget::CursorPositionLabel` and `Widget::ScrollPositionLabel`: status
# bar fields that follow a view on their own — the caret's line and
# column, and vi's All/Top/Bot/percent reading position.

describe "Widget::CursorPositionLabel" do
  it "shows the caret's 1-based line and column, following the caret" do
    s = headless_screen(40, 8)
    e = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 40, height: 4
    e.plain_text = "first\nsecond\nthird"
    label = Widget::CursorPositionLabel.new e, parent: s, top: 6, left: 0, width: 20
    s.repaint
    label.text.should eq "Ln 1, Col 1"
    e.cursor_position = e.document.block_position(2) + 3
    label.text.should eq "Ln 3, Col 4"
    e.cursor_position = e.document.block_position(1)
    label.text.should eq "Ln 2, Col 1"
    s.destroy
  end

  it "renders with a custom format, and gives the text alone" do
    s = headless_screen(40, 8)
    e = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 40, height: 4
    e.plain_text = "a\nbc"
    e.cursor_position = 3
    vi = ->(line : Int32, column : Int32) { "#{line},#{column}" }
    label = Widget::CursorPositionLabel.new e, vi, parent: s, top: 6, left: 0, width: 20
    label.text.should eq "2,2"
    label.format = Widget::CursorPositionLabel::DEFAULT_FORMAT
    label.text.should eq "Ln 2, Col 2"
    Widget::CursorPositionLabel.text_for(e, vi).should eq "2,2"
    s.destroy
  end

  it "stops following the view once destroyed" do
    s = headless_screen(40, 8)
    e = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 40, height: 4
    before = e.handlers(Crysterm::Event::CursorPositionChanged).size
    label = Widget::CursorPositionLabel.new e, parent: s, top: 6, left: 0, width: 20
    e.handlers(Crysterm::Event::CursorPositionChanged).size.should eq before + 1
    label.destroy
    e.handlers(Crysterm::Event::CursorPositionChanged).size.should eq before
    s.destroy
  end
end

describe "Widget::ScrollPositionLabel" do
  it "reads All when the content fits, else Top, a percentage and Bot" do
    s = headless_screen(40, 10)
    tb = Widget::TextBrowser.new parent: s, left: 0, top: 0, width: 40, height: 8
    tb.set_markdown "short"
    label = Widget::ScrollPositionLabel.new tb, parent: s, top: 9, left: 0, width: 6
    s.repaint
    label.refresh
    label.text.should eq "All"
    tb.set_markdown (1..60).map { |i| "line #{i}" }.join("\n\n")
    s.repaint
    label.refresh
    label.text.should eq "Top"
    tb.scroll_to 30
    s.repaint
    label.text.should match /\A\d+%\z/
    label.text.should_not eq "Top"
    tb.scroll_percent = 1.0
    s.repaint
    label.text.should eq "Bot"
    tb.scroll_to 0
    s.repaint
    label.text.should eq "Top"
    s.destroy
  end
end
