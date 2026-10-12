require "./spec_helper"

include Crysterm

# `AbstractScrollArea#line_numbers=` on the rich text views (`TextEdit`,
# `TextBrowser`): a rendered document has no source lines, so the gutter
# numbers the rows as laid out, 1 to N from the top of the document —
# wrapped rows and the blank rows between blocks each counted — and the
# text, its pictures, the caret, the mouse and the links all count from the
# gutter's edge.

private IMAGE_DIR = File.expand_path("#{__DIR__}/../data/image")

private def browser(s, markdown, width = 30, height = 8)
  tb = Widget::TextBrowser.new parent: s, left: 0, top: 0, width: width, height: height
  tb.document.base_url = IMAGE_DIR
  tb.set_markdown markdown
  tb
end

private def click(s, x, y)
  s.dispatch_mouse ::Tput::Mouse::Event.new(
    ::Tput::Mouse::Action::Down, ::Tput::Mouse::Button::Left, x, y, source: :test)
  s.dispatch_mouse ::Tput::Mouse::Event.new(
    ::Tput::Mouse::Action::Up, ::Tput::Mouse::Button::Left, x, y, source: :test)
end

# A browser whose row count crosses a digit back and forth with the gutter's
# width, as a picture shrunk to the text width can make it: 100 rows beside a
# three-column gutter, 99 beside a four-column one.
private class FlippingRowsBrowser < Widget::TextBrowser
  getter layouts = 0

  protected def line_number_count : Int32
    @line_number_width <= 3 ? 100 : 99
  end

  private def rebuild_layout(colwidth : Int32, key : Tuple(Int32, Int32, Bool, Int32)) : Nil
    @layouts += 1
    super
  end
end

describe "TextEdit line numbers" do
  it "is off by default and reserves nothing" do
    s = headless_screen(30, 8, default_quit_keys: true)
    tb = browser(s, "one")
    s.repaint
    tb.line_numbers?.should be_false
    tb.line_number_area_width.should eq 0
    row_text(s, 0).should eq "one"
  end

  it "numbers every rendered row, the wrapped ones and the blank ones between blocks too" do
    s = headless_screen(30, 8, default_quit_keys: true)
    # 30 columns, 3 for the gutter and 1 for the caret: 26 for the text.
    tb = browser(s, "aaaa bbbb cccc dddd eeee ffff gggg\n\nnext")
    tb.line_numbers = true
    s.repaint
    tb.line_number_area_width.should eq 3
    row_text(s, 0).should eq " 1 aaaa bbbb cccc dddd eeee"
    row_text(s, 1).should eq " 2 ffff gggg"
    row_text(s, 2).should eq " 3"
    row_text(s, 3).should eq " 4 next"
    # Past the document's end the gutter is blank.
    row_text(s, 4).should eq ""
  end

  it "follows the scroll" do
    s = headless_screen(30, 6, default_quit_keys: true)
    tb = browser(s, (1..20).map { |i| "p#{i}" }.join("\n\n"), height: 6)
    tb.line_numbers = true
    s.repaint
    tb.scroll_to 10
    s.repaint
    row_text(s, 0, 0..9).should eq "11 p6     "
    row_text(s, 1, 0..9).should eq "12        "
  end

  it "widens with the row count in the frame the count changes in" do
    s = headless_screen(30, 6, default_quit_keys: true)
    # 50 paragraphs: 99 rows, then a 51st makes 101.
    tb = browser(s, (1..50).map { |i| "p#{i}" }.join("\n\n"), height: 6)
    tb.line_numbers = true
    s.repaint
    tb.line_number_area_width.should eq 3
    row_text(s, 0, 0..9).should eq " 1 p1     "
    tb.set_markdown (1..51).map { |i| "p#{i}" }.join("\n\n")
    s.repaint
    tb.line_number_area_width.should eq 4
    row_text(s, 0, 0..9).should eq "  1 p1    "
    tb.scroll_to 100
    s.repaint
    row_text(s, 5, 0..9).should eq "101 p51   "
  end

  it "counts the caret and the mouse from the gutter's edge, and a click on a link follows it" do
    s = headless_screen(30, 8, default_quit_keys: true)
    tb = browser(s, "go [one](u://1) now")
    tb.line_numbers = true
    tb.focus
    s.repaint
    tb.ileft.should eq 3
    tb.position_at(3, 0).should eq 0
    tb.position_at(6, 0).should eq 3
    clicked = [] of String
    tb.on(Crysterm::Event::AnchorClick) { |e| clicked << e.url }
    click s, 6, 0 # the 'o' of "one", 3 gutter columns in
    clicked.should eq ["u://1"]
    click s, 1, 0 # the gutter: no link
    clicked.should eq ["u://1"]
  end

  it "puts a picture right of the gutter" do
    s = headless_screen(40, 12, default_quit_keys: true)
    tb = browser(s, "![Matterhorn](matterhorn.png)", width: 40, height: 12)
    s.repaint
    left = tb.block_media[0].aleft
    tb.line_numbers = true
    s.repaint
    tb.block_media[0].aleft.should eq left + 3
    # The picture's rows are rows of the document, numbered like any other.
    row_text(s, 1, 0..2).should eq " 2 "
  end

  it "keeps the caret's row in the widget's foreground, the others faded, and carries the current-line tint" do
    saved_theme = Crysterm::CSS.theme
    s = headless_screen(30, 8, default_quit_keys: true)
    Crysterm::CSS.theme = nil
    tb = browser(s, "one\n\ntwo")
    tb.style.fg = 0xffffff
    tb.style.bg = 0x000000
    tb.line_numbers = true
    tb.cursor_position = 0
    s.repaint
    Attr.fg(s.cell_rows[0][1].attr).should eq Attr.pack_color(0xffffff)
    faded = Attr.unpack_color(Attr.fg(s.cell_rows[2][1].attr))
    faded.should_not eq 0xffffff
    faded.should_not eq 0x000000

    tb.highlight_current_line = true
    s.repaint
    Attr.bg(s.cell_rows[0][1].attr).should eq Attr.bg(s.cell_rows[0][4].attr)
    Attr.bg(s.cell_rows[0][1].attr).should_not eq Attr.pack_color(0x000000)
    Attr.bg(s.cell_rows[2][1].attr).should eq Attr.pack_color(0x000000)

    s.stylesheet = "TextBrowser::line-number { color: #ff0000; }"
    s.repaint
    Attr.fg(s.cell_rows[2][1].attr).should eq Attr.pack_color(0xff0000)
  ensure
    Crysterm::CSS.theme = saved_theme
  end

  it "turns the row ruler into ticks beside it, and reports the toggle" do
    s = headless_screen(30, 8, default_quit_keys: true)
    tb = browser(s, "one\n\ntwo")
    seen = [] of Bool
    tb.on(Event::LineNumbersChanged) { |e| seen << e.visible }
    tb.row_ruler = true
    tb.line_numbers = true
    s.repaint
    row_text(s, 0).should eq " 1 │one"
    row_text(s, 2).should eq " 3 │two"
    tb.line_numbers = false
    s.repaint
    row_text(s, 0).should eq " │one"
    seen.should eq [true, false]
  end

  it "settles on the wider gutter when the row count flips across a digit with its width" do
    s = headless_screen(30, 6, default_quit_keys: true)
    tb = FlippingRowsBrowser.new parent: s, left: 0, top: 0, width: 30, height: 6
    tb.set_markdown "one"
    tb.line_numbers = true
    s.repaint
    tb.line_number_area_width.should eq 4
    # Steady: no layout on the frames after.
    n = tb.layouts
    s.repaint
    s.repaint
    tb.layouts.should eq n
    tb.line_number_area_width.should eq 4
  end

  it "is reachable on a MarkdownViewer's browser" do
    s = headless_screen(40, 8, default_quit_keys: true)
    mv = Widget::MarkdownViewer.new parent: s, left: 0, top: 0, width: 40, height: 8, show_toc: false,
      document: TextDocument.from_markdown("one")
    mv.browser.line_numbers = true
    s.repaint
    row_text(s, 0).should eq " 1 one"
  end
end
