require "./spec_helper"

include Crysterm

# `PlainTextEdit#line_numbers=`: the line-number gutter of Qt's code editor
# example as a view property — numbers on the first row of each source line,
# blank continuation rows, a width that follows the digit count, and text
# geometry (wrap width, caret, mouse) counted from the text's edge.

private def editor(s, content, width = 20, height = 6, wrap = true)
  Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: width, height: height, content: content, wrap_content: wrap
end

describe "PlainTextEdit line numbers" do
  it "is off by default and reserves nothing" do
    s = headless_screen(20, 6, default_quit_keys: true)
    pe = editor(s, "one\ntwo")
    s.repaint
    pe.line_numbers?.should be_false
    pe.line_number_area_width.should eq 0
    row_text(s, 0).should eq "one"
  end

  it "numbers each source line on its first row, right-aligned before a space" do
    s = headless_screen(20, 6, default_quit_keys: true)
    pe = editor(s, "one\ntwo\nthree")
    pe.line_numbers = true
    s.repaint
    pe.line_number_area_width.should eq 3 # two digit columns at least, plus the gap
    row_text(s, 0).should eq " 1 one"
    row_text(s, 1).should eq " 2 two"
    row_text(s, 2).should eq " 3 three"
    row_text(s, 3).should eq ""
  end

  it "leaves the continuation rows of a wrapped line blank and wraps to the width left" do
    s = headless_screen(20, 6, default_quit_keys: true)
    # 20 columns, 3 for the gutter and 1 caret column: 16 text columns.
    pe = editor(s, "aaaa bbbb cccc dddd eeee\nx")
    pe.line_numbers = true
    s.repaint
    row_text(s, 0).should eq " 1 aaaa bbbb cccc"
    row_text(s, 1).should eq "   dddd eeee"
    row_text(s, 2).should eq " 2 x"
  end

  it "grows with the digit count of the line count" do
    s = headless_screen(20, 12, default_quit_keys: true)
    pe = editor(s, (1..9).join('\n'), height: 12)
    pe.line_numbers = true
    s.repaint
    pe.line_number_area_width.should eq 3
    row_text(s, 8).should eq " 9 9"

    pe.append_plain_text "10"
    s.repaint
    pe.line_number_area_width.should eq 3
    row_text(s, 9).should eq "10 10"

    pe.plain_text = (1..100).join('\n') # parks the caret, and the view, at the end
    pe.scroll_to 0
    s.repaint
    pe.line_number_area_width.should eq 4
    row_text(s, 0, 0..5).should eq "  1 1 "
    row_text(s, 9, 0..5).should eq " 10 10"
    pe.cursor_position = pe.to_plain_text.size
    pe.ensure_cursor_visible
    s.repaint
    row_text(s, 11, 0..6).should eq "100 100"
  end

  it "toggling off removes the gutter and restores the wrap width" do
    s = headless_screen(20, 6, default_quit_keys: true)
    # 19 text columns without the gutter, 16 with it: the break moves.
    pe = editor(s, "aaaa bbbb cccc dd eeee ffff")
    s.repaint
    row_text(s, 0).should eq "aaaa bbbb cccc dd"
    pe.line_numbers = true
    s.repaint
    row_text(s, 0).should eq " 1 aaaa bbbb cccc"
    row_text(s, 1).should eq "   dd eeee ffff"
    pe.line_numbers = false
    s.repaint
    pe.line_number_area_width.should eq 0
    row_text(s, 0).should eq "aaaa bbbb cccc dd"
    row_text(s, 1).should eq "eeee ffff"
  end

  it "places the caret and maps a mouse click past the gutter" do
    s = headless_screen(20, 6, default_quit_keys: true)
    pe = editor(s, "hello\nworld")
    pe.line_numbers = true
    pe.focus
    s.repaint
    # Column 3 is the first text column: a click there on row 1 lands at
    # the start of "world"; two columns right of it, after "wo".
    click(s, 3, 1)
    pe.cursor_position.should eq 6
    click(s, 5, 1)
    pe.cursor_position.should eq 8
    # A click inside the gutter snaps to the row's start.
    click(s, 0, 0)
    pe.cursor_position.should eq 0
    # The hardware caret sits past the gutter too.
    pe.cursor_position = 8
    s.repaint
    s.tput.cursor.x.should eq 5
    s.tput.cursor.y.should eq 1
  end

  it "scrolls an unwrapped line horizontally past the gutter, caret at the text's edge" do
    s = headless_screen(20, 8, default_quit_keys: true)
    pe = editor(s, "0123456789abcdefghijklmnop\nz", height: 8, wrap: false)
    pe.line_numbers = true
    pe.focus
    s.repaint
    row_text(s, 0).should eq " 1 0123456789abcdef"
    # The end of the long line, with the view scrolled to show it: 16 text
    # columns, so 10 columns scroll off and the caret sits on the last one.
    pe.cursor_position = 26
    pe.scroll_to_x 10
    s.repaint
    row_text(s, 0).should eq " 1 abcdefghijklmnop"
    row_text(s, 1, 0..3).should eq " 2  "
    s.tput.cursor.x.should eq 19
    # A click maps through the scroll: column 3 is now the 'a' at index 10.
    click(s, 3, 0)
    pe.cursor_position.should eq 10
  end

  it "tints the gutter cells of the caret's row with the current-line highlight" do
    s = headless_screen(20, 6, default_quit_keys: true)
    pe = editor(s, "one\ntwo")
    pe.line_numbers = true
    pe.highlight_current_line = true
    pe.current_line_format = TextCharFormat.new(bg: 0x222244)
    pe.cursor_position = 5
    s.repaint
    Attr.bg(s.cell_rows[1][0].attr).should eq Attr.pack_color(0x222244)
    Attr.bg(s.cell_rows[1][5].attr).should eq Attr.pack_color(0x222244)
    Attr.bg(s.cell_rows[0][0].attr).should_not eq Attr.pack_color(0x222244)
  end

  it "emits LineNumbersChanged on an actual change only" do
    s = headless_screen(20, 6, default_quit_keys: true)
    pe = editor(s, "one")
    seen = [] of Bool
    pe.on(Event::LineNumbersChanged) { |e| seen << e.visible }
    pe.line_numbers = true
    pe.line_numbers = true
    pe.line_numbers = false
    seen.should eq [true, false]
  end

  it "fades the numbers toward the background without a rule, and takes a ::line-number rule" do
    saved_theme = Crysterm::CSS.theme
    s = headless_screen(20, 6, default_quit_keys: true)
    # `ensure_theme` ran on construction; drop the theme so the colors below
    # are the widget's own and no `::line-number` rule is in effect.
    Crysterm::CSS.theme = nil
    pe = editor(s, "one\ntwo")
    pe.style.fg = 0xffffff
    pe.style.bg = 0x000000
    pe.line_numbers = true
    pe.cursor_position = 0
    s.repaint
    # The caret's line keeps the normal foreground; the other line fades.
    Attr.fg(s.cell_rows[0][1].attr).should eq Attr.pack_color(0xffffff)
    faded = Attr.unpack_color(Attr.fg(s.cell_rows[1][1].attr))
    faded.should_not eq 0xffffff
    faded.should_not eq 0x000000
    Attr.bg(s.cell_rows[1][1].attr).should eq Attr.pack_color(0x000000)
    # The text itself is not faded.
    Attr.fg(s.cell_rows[1][3].attr).should eq Attr.pack_color(0xffffff)

    s.stylesheet = "PlainTextEdit::line-number { color: #ff0000; }"
    s.repaint
    Attr.fg(s.cell_rows[1][1].attr).should eq Attr.pack_color(0xff0000)
    Attr.fg(s.cell_rows[1][3].attr).should eq Attr.pack_color(0xffffff)
  ensure
    Crysterm::CSS.theme = saved_theme
  end

  it "keeps the default theme's gutter color while focused" do
    s = headless_screen(20, 6, default_quit_keys: true)
    pe = editor(s, "one\ntwo")
    pe.line_numbers = true
    pe.cursor_position = 0
    pe.focus
    s.repaint
    text_fg = Attr.fg(s.cell_rows[1][3].attr)
    Attr.fg(s.cell_rows[1][1].attr).should_not eq text_fg
    Attr.bg(s.cell_rows[1][1].attr).should eq Attr.bg(s.cell_rows[1][3].attr)
  end
end
