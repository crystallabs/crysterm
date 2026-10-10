require "./spec_helper"

include Crysterm

# `PlainTextEdit#extra_selections=` (Qt `QPlainTextEdit::setExtraSelections`):
# the same `TextEdit::ExtraSelection` overlays, painted by the base renderer
# — a full-width one highlights the caret's whole row (the current-line
# idiom), a ranged one only its columns.

private def xsel(c, fmt, full = false)
  Widget::TextEdit::ExtraSelection.new(c, fmt, full_width: full)
end

describe "PlainTextEdit extra selections" do
  it "paints a full-width selection across the caret's whole row" do
    s = headless_screen(40, 8, default_quit_keys: true)
    pe = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 40, height: 6, content: "one\ntwo\nthree"
    s.repaint
    plain = Attr.bg(s.cell_rows[2][0].attr) # the widget's own background
    pe.cursor_position = 5                  # inside "two"
    pe.extra_selections = [xsel(TextCursor.new(pe.document, 5), TextCharFormat.new(bg: 0x222244), true)]
    s.repaint
    Attr.bg(s.cell_rows[1][0].attr).should eq Attr.pack_color(0x222244)
    Attr.bg(s.cell_rows[1][20].attr).should eq Attr.pack_color(0x222244)
    Attr.bg(s.cell_rows[0][0].attr).should eq plain
    Attr.bg(s.cell_rows[2][0].attr).should eq plain
    s.cell_rows[1][0].char.should eq 't'

    # Re-set at another caret position: the highlight moves.
    pe.extra_selections = [xsel(TextCursor.new(pe.document, 9), TextCharFormat.new(bg: 0x222244), true)]
    s.repaint
    Attr.bg(s.cell_rows[1][0].attr).should eq plain
    Attr.bg(s.cell_rows[2][30].attr).should eq Attr.pack_color(0x222244)

    pe.extra_selections = [] of Widget::TextEdit::ExtraSelection
    s.repaint
    Attr.bg(s.cell_rows[2][30].attr).should eq plain
  end

  it "paints a ranged selection over its columns only" do
    s = headless_screen(40, 8, default_quit_keys: true)
    pe = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 40, height: 6, content: "abcdef\nxyz"
    s.repaint
    plain = Attr.bg(s.cell_rows[1][0].attr)
    pe.extra_selections = [xsel(TextCursor.new(pe.document, 2, 4), TextCharFormat.new(bg: 0x333333, bold: true))]
    s.repaint
    Attr.bg(s.cell_rows[0][1].attr).should eq plain
    Attr.bg(s.cell_rows[0][2].attr).should eq Attr.pack_color(0x333333)
    Attr.bg(s.cell_rows[0][3].attr).should eq Attr.pack_color(0x333333)
    Attr.bg(s.cell_rows[0][4].attr).should eq plain
    (Attr.flags(s.cell_rows[0][2].attr) & Attr::BOLD).should_not eq 0
    Attr.bg(s.cell_rows[1][0].attr).should eq plain
  end
end
