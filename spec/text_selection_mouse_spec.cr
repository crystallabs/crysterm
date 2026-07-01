require "./spec_helper"

include Crysterm

# Mouse-driven cursor positioning and click-drag selection, shared by
# `LineEdit` and `PlainTextEdit` via `Mixin::TextEditing` (`#position_at`,
# `#_setup_text_mouse`, `#selection_anchor`/`#selection_range`). Driven
# headlessly over in-memory IOs, same pattern as `drag_spec.cr` and
# `widget_qt_render_spec.cr`: a real synchronous render (`Window#_render`,
# NOT `Window#render` — the latter only rings the async render-loop doorbell
# and never actually paints in a headless spec with no render fiber running)
# followed by `Window#dispatch_mouse` with synthesized `::Tput::Mouse::Event`s.
#
# `#position_at` reads the widget's on-screen geometry/painted line cache
# (`_get_coords`/`@_clines`/`@_value`), so a widget must be rendered at least
# once before its coordinates mean anything; `#_render` is called right after
# construction (and after any `.value =` that changes wrapping) in every test
# below.

private def sel_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24)
end

private def mouse(action, x, y, button = ::Tput::Mouse::Button::Left)
  ::Tput::Mouse::Event.new(action, button, x, y, source: :test)
end

private def press(s, x, y)
  s.dispatch_mouse mouse(::Tput::Mouse::Action::Down, x, y)
end

# Motion with the (left) button still held — what a drag-to-select reports.
# Distinct from `drag_spec.cr`'s `move` helper, which sends `Button::None`
# (that spec drives the drag-and-drop sensor, which tracks its own armed
# state instead of reading the reported button).
private def drag_move(s, x, y)
  s.dispatch_mouse mouse(::Tput::Mouse::Action::Move, x, y, ::Tput::Mouse::Button::Left)
end

private def release(s, x, y)
  s.dispatch_mouse mouse(::Tput::Mouse::Action::Up, x, y, ::Tput::Mouse::Button::None)
end

describe "Mixin::TextEditing mouse cursor positioning / selection" do
  describe Widget::LineEdit do
    it "moves the cursor to the clicked codepoint index (start/middle/end)" do
      s = sel_screen
      le = Widget::LineEdit.new parent: s, left: 0, top: 0, width: 20, height: 1, content: "hello"
      s._render

      press s, 0, 0
      le.cursor_pos.should eq 0

      press s, 2, 0
      le.cursor_pos.should eq 2

      press s, 5, 0
      le.cursor_pos.should eq 5
    end

    it "clicking past the end of the content lands the cursor at the end, not out of bounds" do
      s = sel_screen
      le = Widget::LineEdit.new parent: s, left: 0, top: 0, width: 20, height: 1, content: "hello"
      s._render

      press s, 999, 0
      le.cursor_pos.should eq le.value.size
      le.cursor_pos.should eq 5
    end

    it "clicking at x=0/y=0 lands at position 0" do
      s = sel_screen
      le = Widget::LineEdit.new parent: s, left: 0, top: 0, width: 20, height: 1, content: "hello"
      s._render

      press s, 0, 0
      le.cursor_pos.should eq 0
    end

    it "a plain click with no drag leaves no selection" do
      s = sel_screen
      le = Widget::LineEdit.new parent: s, left: 0, top: 0, width: 20, height: 1, content: "hello"
      s._render

      # Down with no subsequent move.
      press s, 2, 0
      le.has_selection?.should be_false

      # Down then up at the same position.
      press s, 3, 0
      release s, 3, 0
      le.has_selection?.should be_false
    end

    it "press then drag-move extends the selection to the new position" do
      s = sel_screen
      le = Widget::LineEdit.new parent: s, left: 0, top: 0, width: 20, height: 1, content: "hello"
      s._render

      press s, 2, 0      # cursor_pos = 2, anchor = 2
      drag_move s, 4, 0  # cursor_pos = 4

      le.cursor_pos.should eq 4
      le.selection_anchor.should eq 2
      le.selection_range.should eq(2...4)
      le.selected_text.should eq "ll"
      le.has_selection?.should be_true
    end

    it "dragging backward (right-to-left) still produces a normalized [lo, hi) range" do
      s = sel_screen
      le = Widget::LineEdit.new parent: s, left: 0, top: 0, width: 20, height: 1, content: "hello"
      s._render

      press s, 4, 0
      drag_move s, 1, 0

      le.cursor_pos.should eq 1
      le.selection_anchor.should eq 4
      le.selection_range.should eq(1...4)
      le.selected_text.should eq "ell"
    end

    it "typing a character after a selection clears it" do
      s = sel_screen
      le = Widget::LineEdit.new parent: s, left: 0, top: 0, width: 20, height: 1, content: "hello"
      s._render

      press s, 1, 0
      drag_move s, 3, 0
      le.has_selection?.should be_true

      le._listener Crysterm::Event::KeyPress.new 'X'
      le.has_selection?.should be_false
    end

    it "any keyboard interaction (e.g. arrow key) clears an active selection" do
      s = sel_screen
      le = Widget::LineEdit.new parent: s, left: 0, top: 0, width: 20, height: 1, content: "hello"
      s._render

      press s, 1, 0
      drag_move s, 3, 0
      le.has_selection?.should be_true

      le._listener Crysterm::Event::KeyPress.new '\0', Tput::Key::Right
      le.has_selection?.should be_false
    end

    it "setting .value= externally clears an active selection" do
      s = sel_screen
      le = Widget::LineEdit.new parent: s, left: 0, top: 0, width: 20, height: 1, content: "hello"
      s._render

      press s, 1, 0
      drag_move s, 3, 0
      le.has_selection?.should be_true

      le.value = "goodbye"
      le.has_selection?.should be_false
    end
  end

  describe Widget::PlainTextEdit do
    it "moves the cursor to the clicked codepoint index (start/middle/end) on a single line" do
      s = sel_screen
      pte = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 20, height: 5
      pte.value = "hello world"
      s._render

      press s, 0, 0
      pte.cursor_pos.should eq 0

      press s, 6, 0
      pte.cursor_pos.should eq 6

      press s, 11, 0
      pte.cursor_pos.should eq 11
    end

    it "clicking past the end of the content lands the cursor at the end, not out of bounds" do
      s = sel_screen
      pte = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 20, height: 5
      pte.value = "hello world"
      s._render

      press s, 999, 0
      pte.cursor_pos.should eq pte.value.size
      pte.cursor_pos.should eq 11
    end

    it "clicking at x=0/y=0 lands at position 0" do
      s = sel_screen
      pte = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 20, height: 5
      pte.value = "hello world"
      s._render

      press s, 0, 0
      pte.cursor_pos.should eq 0
    end

    it "a plain click with no drag leaves no selection" do
      s = sel_screen
      pte = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 20, height: 5
      pte.value = "hello world"
      s._render

      press s, 4, 0
      pte.has_selection?.should be_false

      press s, 6, 0
      release s, 6, 0
      pte.has_selection?.should be_false
    end

    it "press then drag-move extends the selection to the new position" do
      s = sel_screen
      pte = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 20, height: 5
      pte.value = "hello world"
      s._render

      press s, 0, 0
      drag_move s, 5, 0

      pte.cursor_pos.should eq 5
      pte.selection_range.should eq(0...5)
      pte.selected_text.should eq "hello"
    end

    it "typing a character after a selection clears it" do
      s = sel_screen
      pte = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 20, height: 5
      pte.value = "hello world"
      s._render

      press s, 0, 0
      drag_move s, 5, 0
      pte.has_selection?.should be_true

      pte._listener Crysterm::Event::KeyPress.new 'X'
      pte.has_selection?.should be_false
    end

    it "setting .value= externally clears an active selection" do
      s = sel_screen
      pte = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 20, height: 5
      pte.value = "hello world"
      s._render

      press s, 0, 0
      drag_move s, 5, 0
      pte.has_selection?.should be_true

      pte.value = "replaced"
      pte.has_selection?.should be_false
    end

    it "a selection spanning two logical (newline-separated) lines includes the embedded \\n" do
      s = sel_screen
      pte = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 20, height: 5
      pte.value = "line one\nline two"
      s._render

      # Row 0 col 5 -> index 5 ("line one"[5] == 'o' of "one", start of "one").
      # Row 1 col 5 -> index 9 (after "line one\n") + 5 == 14.
      press s, 5, 0
      drag_move s, 5, 1

      pte.cursor_pos.should eq 14
      pte.selection_range.should eq(5...14)
      pte.selected_text.should eq "one\nline "
      pte.selected_text.should contain "\n"
    end

    it "a selection spanning a wrapped (soft-wrapped) single line matches the expected substring" do
      s = sel_screen
      # width 12 minus the 1-column caret margin (`content_margin_x`) leaves an
      # 11-column wrap width, so a 16-char line with no spaces wraps at 11:
      # row 0 = "abcdefghijk", row 1 = "lmnop".
      pte = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 12, height: 5
      pte.value = "abcdefghijklmnop"
      s._render
      pte.content_width.should eq 11

      press s, 0, 0     # row 0, col 0 -> index 0
      drag_move s, 2, 1 # row 1, col 2 -> index 11 + 2 = 13

      pte.cursor_pos.should eq 13
      pte.selection_range.should eq(0...13)
      pte.selected_text.should eq "abcdefghijklm"
      # A soft wrap is not a real newline in `@value`.
      pte.selected_text.should_not contain "\n"
    end
  end
end
