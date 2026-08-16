require "./spec_helper"

include Crysterm

# `Widget::TextEdit` selection & overlays: mouse positioning/drag-selection
# through the shared `Mixin::TextEditing` machinery running over the
# document adapter, the reverse-video selection highlight, and
# `ExtraSelection` format overlays incl. the full-width current-line
# highlight.

# A drag-to-select motion with the (left) button still held.
private def drag_move(s, x, y)
  mouse_move(s, x, y, ::Tput::Mouse::Button::Left)
end

private def ctl(k : ::Tput::Key)
  kp key: k
end

private def reversed?(s, x, y)
  (Attr.flags(s.cell_rows[y][x].attr) & Attr::REVERSE) != 0
end

describe Widget::TextEdit do
  it "positions the caret from a mouse click, across blocks" do
    s = headless_screen(40, 8, default_quit_keys: true)
    te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 40, height: 6,
      content: "one\ntwo\nthree"
    s.repaint

    mouse_down s, 2, 1
    te.cursor_pos.should eq 6 # "one\n tw|o" -> block 1, offset 2

    mouse_down s, 5, 2
    te.cursor_pos.should eq 13 # past "three" -> end of the document
  end

  it "drag-selects and paints the selection reversed" do
    s = headless_screen(40, 8, default_quit_keys: true)
    te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 40, height: 6,
      content: "hello world"
    s.repaint

    mouse_down s, 0, 0
    drag_move s, 5, 0
    te.selected_text.should eq "hello"

    s.repaint
    reversed?(s, 0, 0).should be_true
    reversed?(s, 4, 0).should be_true
    reversed?(s, 6, 0).should be_false
  end

  it "a selection spanning blocks selects across the separator" do
    s = headless_screen(40, 8, default_quit_keys: true)
    te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 40, height: 6,
      content: "one\ntwo"
    s.repaint

    mouse_down s, 1, 0
    drag_move s, 2, 1
    te.selected_text.should eq "ne\ntw"

    s.repaint
    reversed?(s, 1, 0).should be_true
    reversed?(s, 1, 1).should be_true
    reversed?(s, 2, 1).should be_false
  end

  it "typing over a selection replaces it in one undo step" do
    s = headless_screen(40, 8, default_quit_keys: true)
    te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 40, height: 6,
      content: "hello world"
    s.repaint

    mouse_down s, 0, 0
    drag_move s, 5, 0
    te._listener kp('H')
    te.value.should eq "H world"

    te._listener ctl(::Tput::Key::CtrlZ)
    te.value.should eq "hello world"
  end

  it "shift-selection over the document highlights and collapses like the flat editors" do
    s = headless_screen(40, 8, default_quit_keys: true)
    te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 40, height: 6,
      content: "abcdef"
    s.repaint

    te.cursor_pos = 0
    3.times { te._listener ctl(::Tput::Key::ShiftRight) }
    te.selected_text.should eq "abc"

    te._listener ctl(::Tput::Key::Left) # collapse to selection start
    te.cursor_pos.should eq 0
    te.selection?.should be_false
  end

  it "applies a ranged ExtraSelection as a format overlay" do
    s = headless_screen(40, 8, default_quit_keys: true)
    te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 40, height: 6,
      content: "overlay target"
    s.repaint

    c = TextCursor.new(te.document)
    c.set_position(0)
    c.set_position(7, :keep_anchor)
    te.extra_selections = [Widget::TextEdit::ExtraSelection.new(c, TextCharFormat.new(bg: 0x333333))]
    s.repaint

    Attr.bg(s.cell_rows[0][0].attr).should eq Attr.pack_color(0x333333)
    Attr.bg(s.cell_rows[0][6].attr).should eq Attr.pack_color(0x333333)
    Attr.bg(s.cell_rows[0][8].attr).should eq Attr.pack_color(-1)

    # The overlay is render-time only: the document text carries no bg.
    te.document.typing_format_at(1).bg.should be_nil
  end

  it "a full-width ExtraSelection highlights the caret's whole row (current line)" do
    s = headless_screen(40, 8, default_quit_keys: true)
    te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 40, height: 6,
      content: "one\ntwo\nthree"
    s.repaint

    te.cursor_pos = 5 # inside "two"
    c = TextCursor.new(te.document, te.cursor_pos)
    te.extra_selections = [Widget::TextEdit::ExtraSelection.new(c, TextCharFormat.new(bg: 0x222244), full_width: true)]
    s.repaint

    # Whole row 1 carries the bg — including cells past the text.
    Attr.bg(s.cell_rows[1][0].attr).should eq Attr.pack_color(0x222244)
    Attr.bg(s.cell_rows[1][20].attr).should eq Attr.pack_color(0x222244)
    # Other rows don't.
    Attr.bg(s.cell_rows[0][0].attr).should eq Attr.pack_color(-1)
    Attr.bg(s.cell_rows[2][0].attr).should eq Attr.pack_color(-1)
  end

  it "extra selections merge over char formats without erasing them" do
    s = headless_screen(40, 8, default_quit_keys: true)
    te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 40, height: 6,
      content: "bold"
    te.document.cursor(0, 4).set_char_format(TextCharFormat.new(bold: true))
    s.repaint

    c = TextCursor.new(te.document)
    c.set_position(0)
    c.set_position(4, :keep_anchor)
    te.extra_selections = [Widget::TextEdit::ExtraSelection.new(c, TextCharFormat.new(bg: 0x111111))]
    s.repaint

    a = s.cell_rows[0][0].attr
    (Attr.flags(a) & Attr::BOLD).should_not eq 0
    Attr.bg(a).should eq Attr.pack_color(0x111111)
  end

  it "double-click selects the word under the pointer" do
    s = headless_screen(40, 8, default_quit_keys: true)
    te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 40, height: 6,
      content: "alpha beta gamma"
    s.repaint

    mouse_down s, 7, 0
    mouse_down s, 7, 0 # second click within the multi-click window
    te.selected_text.should eq "beta"
  end
end
