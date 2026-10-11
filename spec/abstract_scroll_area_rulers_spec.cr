require "./spec_helper"

include Crysterm

# `AbstractScrollArea#rulers=`: a column ruler on the viewport's top row and
# a row ruler down its leftmost columns, reserved as viewport margins like
# the line-number gutter (outside it when both show), counted in the text's
# coordinates — the text width column, its alignment and the horizontal
# scroll move the numbers with the text — and styled by `::ruler`.

private def editor(s, content, width = 30, height = 8, wrap = true)
  Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: width, height: height, content: content, wrap_content: wrap
end

private def viewer(s, content, width = 40, height = 8)
  Widget::TextEdit.new parent: s, left: 0, top: 0, width: width, height: height, content: content
end

describe "AbstractScrollArea rulers" do
  it "is off by default and reserves nothing" do
    s = headless_screen(30, 8)
    pe = editor(s, "one\ntwo")
    s.repaint
    pe.rulers?.should be_false
    row_text(s, 0).should eq "one"
  end

  it "puts the column ruler on the top row and the row ruler down the left, the text below and right of them" do
    s = headless_screen(30, 8)
    pe = editor(s, "one\ntwo")
    pe.rulers = true
    s.repaint
    # Two ruler columns, then the tape from column 1: a `┼` at every fifth
    # column, a `│` on every tenth with its number right after it.
    row_text(s, 0).should eq "  ────┼────│10──┼────│20──┼───"
    row_text(s, 1).should eq " │one"
    row_text(s, 2).should eq " │two"
    # Rows past the document's end are blank on the ruler too.
    row_text(s, 3).should eq ""
    pe.ileft.should eq 2
    pe.itop.should eq 1
  end

  it "numbers every tenth row and ticks every fifth, following the scroll" do
    s = headless_screen(30, 8)
    pe = editor(s, (1..30).map { |i| "l#{i}" }.join('\n'))
    pe.rulers = true
    pe.cursor_position = 0 # the content parks the caret, and the view, at the end
    pe.scroll_to 0
    s.repaint
    row_text(s, 5, 0..1).should eq " ┼" # row 5
    row_text(s, 5, 2..3).should eq "l5"
    pe.scroll_to 7
    s.repaint
    row_text(s, 1, 0..3).should eq " │l8"
    row_text(s, 3, 0..4).should eq "10l10"
    row_text(s, 8 - 1, 0..4).should eq " │l14"
  end

  it "sits outside the line-number gutter" do
    s = headless_screen(30, 8)
    pe = editor(s, "one\ntwo")
    pe.rulers = true
    pe.line_numbers = true
    s.repaint
    row_text(s, 1).should eq " │ 1 one"
    row_text(s, 2).should eq " │ 2 two"
    # Column 1 of the tape is the text's first column, past the gutter.
    row_text(s, 0, 0..9).should eq "     ────┼"
    pe.line_numbers = false
    s.repaint
    row_text(s, 1).should eq " │one"
  end

  it "counts the text's columns: a capped, centered column starts the tape where the text starts" do
    s = headless_screen(40, 8)
    te = viewer(s, "hello world")
    te.rulers = true
    te.line_wrap_column = 20
    te.line_wrap_column_alignment = Tput::AlignFlag::HCenter
    s.repaint
    # 40 columns, 2 for the ruler and 1 for the caret: 37 for the text, 20
    # of them used, so 8 blank at the left before column 1.
    te.ileft.should eq 10
    row_text(s, 0, 0..9).should eq "          "
    row_text(s, 0, 10..19).should eq "────┼────│"
    row_text(s, 1, 10..14).should eq "hello"
  end

  it "slides the tape with a horizontal scroll" do
    s = headless_screen(30, 8)
    pe = editor(s, "0123456789abcdefghijklmnopqrstuvwxyz\nz", wrap: false)
    pe.rulers = true
    pe.focus
    s.repaint
    pe.scroll_to_x 5
    s.repaint
    # The first text column now shows column 6: three dashes, then the 10.
    row_text(s, 0, 2..6).should eq "────│"
    row_text(s, 1, 2..6).should eq "56789"
  end

  it "places the caret and maps a click past the rulers" do
    s = headless_screen(30, 8)
    pe = editor(s, "hello\nworld")
    pe.rulers = true
    pe.focus
    s.repaint
    click(s, 4, 2)
    pe.cursor_position.should eq 8
    pe.cursor_position = 2
    s.repaint
    s.tput.cursor.x.should eq 4
    s.tput.cursor.y.should eq 1
  end

  it "widens the row ruler with the row count and gives the band back when turned off" do
    s = headless_screen(30, 12)
    pe = editor(s, (1..120).join('\n'), height: 12)
    pe.rulers = true
    pe.cursor_position = 0
    pe.scroll_to 0
    s.repaint
    s.repaint # the width settles the frame after the one that counted the rows
    pe.ileft.should eq 3
    row_text(s, 1, 0..3).should eq "  │1"
    row_text(s, 10, 0..4).should eq " 1010"
    pe.rulers = false
    s.repaint
    pe.ileft.should eq 0
    pe.itop.should eq 0
    row_text(s, 0, 0..3).should eq "1   "
  end

  it "shows the column ruler and the row ruler one at a time" do
    s = headless_screen(30, 8)
    pe = editor(s, "one\ntwo")
    pe.column_ruler = true
    s.repaint
    pe.rulers?.should be_true
    pe.row_ruler?.should be_false
    pe.itop.should eq 1
    pe.ileft.should eq 0
    row_text(s, 0, 0..9).should eq "────┼────│"
    row_text(s, 1).should eq "one"
    pe.column_ruler = false
    pe.row_ruler = true
    s.repaint
    pe.itop.should eq 0
    pe.ileft.should eq 2
    row_text(s, 0).should eq " │one"
    row_text(s, 1).should eq " │two"
    pe.rulers = false
    pe.rulers?.should be_false
    pe.row_ruler?.should be_false
    s.repaint
    row_text(s, 0).should eq "one"
  end

  it "emits RulersChanged on an actual change only" do
    s = headless_screen(30, 8)
    pe = editor(s, "one")
    seen = [] of Bool
    pe.on(Event::RulersChanged) { |e| seen << e.visible }
    pe.rulers = true
    pe.rulers = true
    pe.rulers = false
    seen.should eq [true, false]
  end

  it "fades the rulers toward the background without a rule, and takes a ::ruler rule" do
    saved_theme = Crysterm::CSS.theme
    s = headless_screen(30, 8)
    Crysterm::CSS.theme = nil
    pe = editor(s, "one\ntwo")
    pe.style.fg = 0xffffff
    pe.style.bg = 0x000000
    pe.rulers = true
    s.repaint
    faded = Attr.unpack_color(Attr.fg(s.cell_rows[0][5].attr))
    faded.should_not eq 0xffffff
    faded.should_not eq 0x000000
    Attr.bg(s.cell_rows[0][5].attr).should eq Attr.pack_color(0x000000)
    Attr.fg(s.cell_rows[1][2].attr).should eq Attr.pack_color(0xffffff)

    s.stylesheet = "AbstractScrollArea::ruler { color: #ff0000; }"
    s.repaint
    Attr.fg(s.cell_rows[0][5].attr).should eq Attr.pack_color(0xff0000)
    Attr.fg(s.cell_rows[1][1].attr).should eq Attr.pack_color(0xff0000)
    Attr.fg(s.cell_rows[1][2].attr).should eq Attr.pack_color(0xffffff)
  ensure
    Crysterm::CSS.theme = saved_theme
  end

  it "keeps the default theme's ruler color apart from the text" do
    s = headless_screen(30, 8)
    pe = editor(s, "one\ntwo")
    pe.rulers = true
    s.repaint
    Attr.fg(s.cell_rows[0][5].attr).should_not eq Attr.fg(s.cell_rows[1][2].attr)
  end
end
