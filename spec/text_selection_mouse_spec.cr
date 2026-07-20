require "./spec_helper"

include Crysterm

# Mouse-driven cursor positioning and click-drag selection, shared by
# `LineEdit` and `PlainTextEdit` via `Mixin::TextEditing` (`#position_at`,
# `#_setup_text_mouse`, `#selection_anchor`/`#selection_range`). Driven
# headlessly over in-memory IOs, same pattern as `drag_spec.cr` and
# `widget_qt_render_spec.cr`: a real synchronous render (`Window#repaint`,
# NOT `Window#render` — the latter only rings the async render-loop doorbell
# and never actually paints in a headless spec with no render fiber running)
# followed by `Window#dispatch_mouse` with synthesized `::Tput::Mouse::Event`s.
#
# `#position_at` reads the widget's on-screen geometry/painted line cache
# (`coords`/`@_clines`/`@_value`), so a widget must be rendered at least
# once before its coordinates mean anything; `#repaint` is called right after
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
      s.repaint

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
      s.repaint

      press s, 999, 0
      le.cursor_pos.should eq le.value.size
      le.cursor_pos.should eq 5
    end

    it "clicking at x=0/y=0 lands at position 0" do
      s = sel_screen
      le = Widget::LineEdit.new parent: s, left: 0, top: 0, width: 20, height: 1, content: "hello"
      s.repaint

      press s, 0, 0
      le.cursor_pos.should eq 0
    end

    it "a plain click with no drag leaves no selection" do
      s = sel_screen
      le = Widget::LineEdit.new parent: s, left: 0, top: 0, width: 20, height: 1, content: "hello"
      s.repaint

      # Down with no subsequent move.
      press s, 2, 0
      le.selection?.should be_false

      # Down then up at the same position.
      press s, 3, 0
      release s, 3, 0
      le.selection?.should be_false
    end

    it "press then drag-move extends the selection to the new position" do
      s = sel_screen
      le = Widget::LineEdit.new parent: s, left: 0, top: 0, width: 20, height: 1, content: "hello"
      s.repaint

      press s, 2, 0     # cursor_pos = 2, anchor = 2
      drag_move s, 4, 0 # cursor_pos = 4

      le.cursor_pos.should eq 4
      le.selection_anchor.should eq 2
      le.selection_range.should eq(2...4)
      le.selected_text.should eq "ll"
      le.selection?.should be_true
    end

    it "dragging backward (right-to-left) still produces a normalized [lo, hi) range" do
      s = sel_screen
      le = Widget::LineEdit.new parent: s, left: 0, top: 0, width: 20, height: 1, content: "hello"
      s.repaint

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
      s.repaint

      press s, 1, 0
      drag_move s, 3, 0
      le.selection?.should be_true

      le._listener Crysterm::Event::KeyPress.new 'X'
      le.selection?.should be_false
    end

    it "any keyboard interaction (e.g. arrow key) clears an active selection" do
      s = sel_screen
      le = Widget::LineEdit.new parent: s, left: 0, top: 0, width: 20, height: 1, content: "hello"
      s.repaint

      press s, 1, 0
      drag_move s, 3, 0
      le.selection?.should be_true

      le._listener Crysterm::Event::KeyPress.new '\0', Tput::Key::Right
      le.selection?.should be_false
    end

    it "setting .value= externally clears an active selection" do
      s = sel_screen
      le = Widget::LineEdit.new parent: s, left: 0, top: 0, width: 20, height: 1, content: "hello"
      s.repaint

      press s, 1, 0
      drag_move s, 3, 0
      le.selection?.should be_true

      le.value = "goodbye"
      le.selection?.should be_false
    end
  end

  describe Widget::PlainTextEdit do
    it "moves the cursor to the clicked codepoint index (start/middle/end) on a single line" do
      s = sel_screen
      pte = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 20, height: 5
      pte.value = "hello world"
      s.repaint

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
      s.repaint

      press s, 999, 0
      pte.cursor_pos.should eq pte.value.size
      pte.cursor_pos.should eq 11
    end

    it "clicking at x=0/y=0 lands at position 0" do
      s = sel_screen
      pte = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 20, height: 5
      pte.value = "hello world"
      s.repaint

      press s, 0, 0
      pte.cursor_pos.should eq 0
    end

    it "a plain click with no drag leaves no selection" do
      s = sel_screen
      pte = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 20, height: 5
      pte.value = "hello world"
      s.repaint

      press s, 4, 0
      pte.selection?.should be_false

      press s, 6, 0
      release s, 6, 0
      pte.selection?.should be_false
    end

    it "press then drag-move extends the selection to the new position" do
      s = sel_screen
      pte = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 20, height: 5
      pte.value = "hello world"
      s.repaint

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
      s.repaint

      press s, 0, 0
      drag_move s, 5, 0
      pte.selection?.should be_true

      pte._listener Crysterm::Event::KeyPress.new 'X'
      pte.selection?.should be_false
    end

    it "setting .value= externally clears an active selection" do
      s = sel_screen
      pte = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 20, height: 5
      pte.value = "hello world"
      s.repaint

      press s, 0, 0
      drag_move s, 5, 0
      pte.selection?.should be_true

      pte.value = "replaced"
      pte.selection?.should be_false
    end

    it "a selection spanning two logical (newline-separated) lines includes the embedded \\n" do
      s = sel_screen
      pte = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 20, height: 5
      pte.value = "line one\nline two"
      s.repaint

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
      s.repaint
      pte.content_width.should eq 11

      press s, 0, 0     # row 0, col 0 -> index 0
      drag_move s, 2, 1 # row 1, col 2 -> index 11 + 2 = 13

      pte.cursor_pos.should eq 13
      pte.selection_range.should eq(0...13)
      pte.selected_text.should eq "abcdefghijklm"
      # A soft wrap is not a real newline in `@value`.
      pte.selected_text.should_not contain "\n"
    end

    # Regression coverage for the cached logical-line-offset lookup that backs
    # `#fake_line_bounds` (OPT.md G3). These exercise it through the public
    # `#position_at` (mouse mapping) / Up-Down (`#pos_from_rowcol`) surface: a
    # wrong or stale offset table lands the caret on the wrong logical line.
    it "maps a click on a later logical line past a TAB-containing line to the right index" do
      s = sel_screen
      pte = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 20, height: 5
      # Line 0 "\tab" holds a TAB (renders as 4 columns) but is only 3 chars in
      # `@value`; line 1 "xy" starts at raw index 4. `#fake_line_bounds(1)` must
      # return the RAW span {4, 6}, not a tab-expanded one.
      pte.value = "\tab\nxy"
      s.repaint

      press s, 1, 1 # row 1, col 1 -> "xy"[1] -> raw index 4 + 1 = 5
      pte.cursor_pos.should eq 5

      press s, 0, 1 # row 1, col 0 -> raw index 4
      pte.cursor_pos.should eq 4
    end

    it "rebuilds the line-offset cache after the buffer changes (no stale mapping)" do
      s = sel_screen
      pte = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 20, height: 5
      pte.value = "\tab\nxy"
      s.repaint
      # Assert straight through `#position_at` (the mouse-coord → raw-index map
      # that reads `#fake_line_bounds` → `#line_offsets`) rather than through a
      # `press`: consecutive mouse-Downs across an external `value=` have their
      # own caret-arming semantics unrelated to the offset cache under test.
      pte.position_at(0, 1).should eq 4 # row 1 ("xy") begins at raw index 4

      # Shrink line 0: row 1 now begins at raw index 2. A stale offset cache would
      # keep mapping row 1 to the old index 4.
      pte.value = "z\nxy"
      s.repaint
      pte.position_at(0, 1).should eq 2
      pte.position_at(1, 1).should eq 3 # "xy"[1] -> raw index 2 + 1
    end

    it "keeps a selection's highlight stable across repeated renders (warm cache)" do
      s = sel_screen
      pte = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 20, height: 5
      pte.value = "a\tb\ncde\nfgh"
      s.repaint

      press s, 0, 0
      drag_move s, 2, 2 # extend down two rows

      first = pte.selected_text
      # Re-render several times: the cache is reused, the mapping must not drift.
      3.times { s.repaint }
      pte.selected_text.should eq first
      pte.selection_range.should eq(0...pte.cursor_pos)
      pte.selected_text.should contain "\n"
    end
  end
end
