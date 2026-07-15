require "./spec_helper"

include Crysterm

# `Widget::TextEdit` selection & overlays: mouse positioning/drag-selection
# through the shared `Mixin::TextEditing` machinery running over the
# document adapter, the reverse-video selection highlight, and
# `ExtraSelection` format overlays incl. the full-width current-line
# highlight (TEXTEDIT.md Phase 2).

private def te_screen(width = 40, height = 8)
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: width,
    height: height)
end

private def mouse(action, x, y, button = ::Tput::Mouse::Button::Left)
  ::Tput::Mouse::Event.new(action, button, x, y, source: :test)
end

private def press(s, x, y)
  s.dispatch_mouse mouse(::Tput::Mouse::Action::Down, x, y)
end

private def drag_move(s, x, y)
  s.dispatch_mouse mouse(::Tput::Mouse::Action::Move, x, y, ::Tput::Mouse::Button::Left)
end

private def key(char : Char, k : ::Tput::Key? = nil)
  Crysterm::Event::KeyPress.new char, k
end

private def ctl(k : ::Tput::Key)
  Crysterm::Event::KeyPress.new '\0', k
end

private def reversed?(s, x, y)
  (Attr.flags(s.lines[y][x].attr) & Attr::REVERSE) != 0
end

describe Widget::TextEdit do
  it "positions the caret from a mouse click, across blocks" do
    s = te_screen
    te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 40, height: 6,
      content: "one\ntwo\nthree"
    s._render

    press s, 2, 1
    te.cursor_pos.should eq 6 # "one\n tw|o" -> block 1, offset 2

    press s, 5, 2
    te.cursor_pos.should eq 13 # past "three" -> end of the document
  end

  it "drag-selects and paints the selection reversed" do
    s = te_screen
    te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 40, height: 6,
      content: "hello world"
    s._render

    press s, 0, 0
    drag_move s, 5, 0
    te.selected_text.should eq "hello"

    s._render
    reversed?(s, 0, 0).should be_true
    reversed?(s, 4, 0).should be_true
    reversed?(s, 6, 0).should be_false
  end

  it "a selection spanning blocks selects across the separator" do
    s = te_screen
    te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 40, height: 6,
      content: "one\ntwo"
    s._render

    press s, 1, 0
    drag_move s, 2, 1
    te.selected_text.should eq "ne\ntw"

    s._render
    reversed?(s, 1, 0).should be_true
    reversed?(s, 1, 1).should be_true
    reversed?(s, 2, 1).should be_false
  end

  it "typing over a selection replaces it in one undo step" do
    s = te_screen
    te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 40, height: 6,
      content: "hello world"
    s._render

    press s, 0, 0
    drag_move s, 5, 0
    te._listener key('H')
    te.value.should eq "H world"

    te._listener ctl(::Tput::Key::CtrlZ)
    te.value.should eq "hello world"
  end

  it "shift-selection over the document highlights and collapses like the flat editors" do
    s = te_screen
    te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 40, height: 6,
      content: "abcdef"
    s._render

    te.cursor_pos = 0
    3.times { te._listener ctl(::Tput::Key::ShiftRight) }
    te.selected_text.should eq "abc"

    te._listener ctl(::Tput::Key::Left) # collapse to selection start
    te.cursor_pos.should eq 0
    te.selection?.should be_false
  end

  it "applies a ranged ExtraSelection as a format overlay" do
    s = te_screen
    te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 40, height: 6,
      content: "overlay target"
    s._render

    c = TextCursor.new(te.document)
    c.set_position(0)
    c.set_position(7, :keep_anchor)
    te.extra_selections = [Widget::TextEdit::ExtraSelection.new(c, TextCharFormat.new(bg: 0x333333))]
    s._render

    Attr.bg(s.lines[0][0].attr).should eq Attr.pack_color(0x333333)
    Attr.bg(s.lines[0][6].attr).should eq Attr.pack_color(0x333333)
    Attr.bg(s.lines[0][8].attr).should eq Attr.pack_color(-1)

    # The overlay is render-time only: the document text carries no bg.
    te.document.char_format_at(1).bg.should be_nil
  end

  it "a full-width ExtraSelection highlights the caret's whole row (current line)" do
    s = te_screen
    te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 40, height: 6,
      content: "one\ntwo\nthree"
    s._render

    te.cursor_pos = 5 # inside "two"
    c = TextCursor.new(te.document, te.cursor_pos)
    te.extra_selections = [Widget::TextEdit::ExtraSelection.new(c, TextCharFormat.new(bg: 0x222244), full_width: true)]
    s._render

    # Whole row 1 carries the bg — including cells past the text.
    Attr.bg(s.lines[1][0].attr).should eq Attr.pack_color(0x222244)
    Attr.bg(s.lines[1][20].attr).should eq Attr.pack_color(0x222244)
    # Other rows don't.
    Attr.bg(s.lines[0][0].attr).should eq Attr.pack_color(-1)
    Attr.bg(s.lines[2][0].attr).should eq Attr.pack_color(-1)
  end

  it "extra selections merge over char formats without erasing them" do
    s = te_screen
    te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 40, height: 6,
      content: "bold"
    te.document.apply_char_format(0, 4, TextCharFormat.new(bold: true))
    s._render

    c = TextCursor.new(te.document)
    c.set_position(0)
    c.set_position(4, :keep_anchor)
    te.extra_selections = [Widget::TextEdit::ExtraSelection.new(c, TextCharFormat.new(bg: 0x111111))]
    s._render

    a = s.lines[0][0].attr
    (Attr.flags(a) & Attr::BOLD).should_not eq 0
    Attr.bg(a).should eq Attr.pack_color(0x111111)
  end

  it "double-click selects the word under the pointer" do
    s = te_screen
    te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 40, height: 6,
      content: "alpha beta gamma"
    s._render

    press s, 7, 0
    press s, 7, 0 # second click within the multi-click window
    te.selected_text.should eq "beta"
  end
end
