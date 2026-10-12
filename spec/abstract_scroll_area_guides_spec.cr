require "./spec_helper"

include Crysterm

# `AbstractScrollArea#guides_enabled=`: vertical guide lines at text columns —
# the two automatic bounds of the text's column and the user's `#guides` —
# drawn in the blank cells of their column under the `::guide` color, and
# made, moved and removed by pulling them off the column ruler with the
# mouse.

private def editor(s, content, width = 30, height = 8, wrap = true)
  Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: width, height: height, content: content, wrap_content: wrap
end

private def drag(s, x0, y0, x1, y1)
  mouse_down(s, x0, y0)
  mouse_move(s, x1, y1, ::Tput::Mouse::Button::Left)
  mouse_up(s, x1, y1)
end

describe "AbstractScrollArea guides" do
  it "takes no guide off the blank above the line-number gutter" do
    s = headless_screen(30, 8)
    pe = editor(s, "abcdef\nxy")
    pe.column_ruler = true
    pe.line_numbers = true
    pe.guides_enabled = true
    s.repaint
    drag(s, 1, 0, 8, 2) # above the gutter, where no tape is
    pe.guides.should be_empty
    drag(s, pe.ileft + 4, 0, pe.ileft + 4, 2) # on the tape: column 5
    pe.guides.should eq [5]
  end

  it "is off by default, with no guides of the user's" do
    s = headless_screen(20, 5)
    pe = editor(s, "ab", width: 20, height: 5)
    s.repaint
    pe.guides_enabled?.should be_false
    pe.guides.should be_empty
    row_text(s, 0).should eq "ab"
  end

  it "bounds the text's column: the column after the viewport's text columns, and the one before when there is one" do
    s = headless_screen(20, 5)
    pe = editor(s, "ab", width: 20, height: 5)
    pe.guides_enabled = true
    s.repaint
    # 19 text columns (the caret has the twentieth): the right bound sits
    # on the caret column, the left one is off the viewport.
    pe.text_column_bounds.should eq({0, 20})
    row_text(s, 0).should eq "ab                 │"
    row_text(s, 4).should eq "                   │"
    pe.line_numbers = true
    s.repaint
    # With a gutter, the left bound runs down its gap column.
    row_text(s, 0).should eq " 1│ab              │"
    row_text(s, 3).should eq "  │                │"
  end

  it "marks the capped column's edges, wherever the alignment puts it" do
    s = headless_screen(20, 5)
    pe = editor(s, "ab", width: 20, height: 5)
    pe.guides_enabled = true
    pe.line_wrap_column = 8
    s.repaint
    pe.text_column_bounds.should eq({0, 9})
    row_text(s, 0).should eq "ab      │"
    pe.line_wrap_column_alignment = Tput::AlignFlag::HCenter
    s.repaint
    pe.ileft.should eq 5
    row_text(s, 0).should eq "    │ab      │"
    row_text(s, 2).should eq "    │        │"
  end

  it "draws a guide in blank cells only, keeping a text cell's character and a cell's background" do
    s = headless_screen(20, 5)
    pe = editor(s, "abcdef\n\nab", width: 20, height: 5)
    pe.guides_enabled = true
    pe.guides = [3, 5]
    pe.guides.should eq [3, 5]
    s.repaint
    row_text(s, 0, 0..6).should eq "abcdef "
    row_text(s, 1, 0..6).should eq "  │ │  "
    row_text(s, 2, 0..6).should eq "ab│ │  "
    pe.highlight_current_line = true
    pe.current_line_format = TextCharFormat.new(bg: 0x222244)
    pe.cursor_position = 8
    s.repaint
    row_text(s, 2, 0..6).should eq "ab│ │  "
    Attr.bg(s.cell_rows[2][2].attr).should eq Attr.pack_color(0x222244)
  end

  it "hangs the guides from the column ruler" do
    s = headless_screen(30, 8)
    pe = editor(s, "hello")
    pe.rulers = true
    pe.guides_enabled = true
    pe.add_guide(5).should be_true
    pe.add_guide(5).should be_false
    s.repaint
    # The ruler's tape, with a `┬` on column 5 (screen column 6) and on the
    # right bound (column 28, the caret column).
    row_text(s, 0, 2..9).should eq "────┬───"
    row_text(s, 0, 29..29).should eq "┬"
    row_text(s, 1, 0..7).should eq " │hello "
    row_text(s, 2, 0..7).should eq "      │ " # past the end: a blank ruler row
    pe.remove_guide(5).should be_true
    pe.remove_guide(5).should be_false
    s.repaint
    row_text(s, 0, 2..9).should eq "────┼───"
  end

  it "pulls a new guide off the ruler, moves one, and loses one dropped on another or back on the ruler" do
    s = headless_screen(30, 8)
    pe = editor(s, "hello\nworld")
    pe.rulers = true
    pe.guides_enabled = true
    pe.focus
    pe.cursor_position = 0
    changes = [] of Array(Int32)
    pe.on(Event::GuidesChanged) { |e| changes << e.columns }
    s.repaint

    # A press on the ruler at column 5 (screen column 6), dragged into the
    # content: a guide at column 5. The caret stayed put.
    drag(s, 6, 0, 6, 3)
    pe.guides.should eq [5]
    pe.cursor_position.should eq 0
    pe.selected_text.should eq ""
    s.repaint
    row_text(s, 3, 0..7).should eq "      │ "
    row_text(s, 0, 2..9).should eq "────┬───"

    # Dragging the guide by its ruler end moves it to where it is dropped.
    drag(s, 6, 0, 9, 2)
    pe.guides.should eq [8]
    # A guide dropped on another guide's column goes.
    pe.add_guide 3
    drag(s, 9, 0, 4, 4)
    pe.guides.should eq [3]
    # One dropped on a bound goes too, and the bound stays.
    drag(s, 4, 0, 29, 4)
    pe.guides.should be_empty
    pe.text_column_bounds.should eq({0, 28})
    # A guide pulled off and put back on the ruler is not made, nor is one
    # clicked without a drag.
    drag(s, 6, 0, 8, 0)
    click(s, 6, 0)
    pe.guides.should be_empty
    # A guide put back where it came from is no change.
    pe.add_guide 5
    changes.clear
    drag(s, 6, 0, 6, 4)
    pe.guides.should eq [5]
    changes.should be_empty
    pe.remove_guide 5
    changes.should eq [[] of Int32]
  end

  it "cannot be pulled without the rulers" do
    s = headless_screen(30, 8)
    pe = editor(s, "hello\nworld")
    pe.guides_enabled = true
    pe.focus
    s.repaint
    # Row 0 is text now: a drag there selects, as always.
    drag(s, 1, 0, 4, 0)
    pe.guides.should be_empty
    pe.selected_text.should eq "ell"
  end

  it "takes a ::guide rule, and fades toward the background without one" do
    saved_theme = Crysterm::CSS.theme
    s = headless_screen(20, 5)
    Crysterm::CSS.theme = nil
    pe = editor(s, "ab", width: 20, height: 5)
    pe.style.fg = 0xffffff
    pe.style.bg = 0x000000
    pe.guides_enabled = true
    s.repaint
    faded = Attr.unpack_color(Attr.fg(s.cell_rows[1][19].attr))
    faded.should_not eq 0xffffff
    faded.should_not eq 0x000000
    s.stylesheet = "AbstractScrollArea::guide { color: #00ff00; }"
    s.repaint
    Attr.fg(s.cell_rows[1][19].attr).should eq Attr.pack_color(0x00ff00)
    Attr.bg(s.cell_rows[1][19].attr).should eq Attr.pack_color(0x000000)
  ensure
    Crysterm::CSS.theme = saved_theme
  end
end

describe "AbstractScrollArea guides, scrolled and in a viewer" do
  it "marks a viewer's capped column's right edge too, in the slack beside the text" do
    s = headless_screen(40, 5)
    te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 40, height: 5, content: "ab"
    te.guides_enabled = true
    te.line_wrap_column = 20
    te.line_wrap_column_alignment = Tput::AlignFlag::HCenter
    s.repaint
    te.text_column_bounds.should eq({0, 21})
    # 40 columns, one kept for the scroll bar, 20 of text: 9 blank at the
    # left; the bounds stand just outside the text.
    left = te.ileft
    left.should eq 9
    row_text(s, 0, (left - 1)..(left + 20)).should eq "│ab#{" " * 18}│"
  end

  it "keeps a guide scrolled out of the text off the slack beside it" do
    s = headless_screen(40, 5)
    pe = editor(s, "0123456789abcdefghijklmnopqrstuvwxyz\nz", width: 40, height: 5, wrap: false)
    pe.guides_enabled = true
    pe.line_wrap_column = 20
    pe.line_wrap_column_alignment = Tput::AlignFlag::HCenter
    pe.guides = [3]
    pe.focus
    pe.cursor_position = 0
    s.repaint
    # 40 columns, one for the caret, 20 of text: 9 blank at the left.
    pe.ileft.should eq 9
    row_text(s, 2, 8..11).should eq "│  │" # the left bound, then the guide at column 3
    pe.scroll_to_x 5
    s.repaint
    # Column 3 and the left bound are scrolled off: nothing is drawn in the
    # slack; the right bound, the text's column 21, slid five cells left.
    row_text(s, 2, 0..8).should eq " " * 9
    row_text(s, 2, 24..24).should eq "│"
  end
end
