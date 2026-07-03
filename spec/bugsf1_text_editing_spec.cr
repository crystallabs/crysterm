require "./spec_helper"

include Crysterm

# Regression specs for the BUGS-F1 text-editing / interactive findings:
#
#  #4  — Triple-click on an empty logical line planted a dangling selection
#        anchor (anchor == caret), so later keystrokes ate characters (and could
#        crash with IndexError). The double-click branch nils the anchor on an
#        empty span; the triple-click branch now does too.
#  #5  — `delete_selection` returned false on the collapsed (no-range) path
#        WITHOUT clearing `@selection_anchor`, so a stale collapsed anchor
#        (Shift+Right then Shift+Left) resurrected as a phantom 1-char selection
#        that swallowed the next keystroke. Now cleared on that path too.
#  #18 — `PlainTextEdit` mixes in both `Mixin::Interactive` (viewport scroll
#        keys) and `Mixin::TextEditing` (editing keys); both fired on the same
#        key while reading. `viewer_scroll_keys?` now stands the Interactive
#        handler down while `@_reading`.
#  #27 — In non-wrap mode each `@_clines[rl]` is only the visible slice, but the
#        caret/selection math used its size as the full line width, so Up/Down
#        snapped a caret past the viewport back to ~viewport width and a
#        selection right of the viewport painted no highlight. Line extents are
#        now derived from `@value` in non-wrap mode.
#
# Same headless harness as bugs8_text_editing_spec.cr / text_editing_keys_spec.cr:
# a Window over in-memory IOs and a synchronous `Window#_render` (so painted-line
# and geometry caches exist) before dispatching synthetic mouse events.

private def f1_screen
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 80, height: 24)
end

private def f1_key(char : Char, k : ::Tput::Key? = nil)
  Crysterm::Event::KeyPress.new char, k
end

private def f1_ctl(k : ::Tput::Key)
  Crysterm::Event::KeyPress.new '\0', k
end

private def f1_mouse(action, x, y)
  ::Tput::Mouse::Event.new(action, ::Tput::Mouse::Button::Left, x, y, source: :test)
end

private def f1_press(s, x, y)
  s.dispatch_mouse f1_mouse(::Tput::Mouse::Action::Down, x, y)
end

# Exposes the protected `selection_columns_for_row` for the #27 selection test.
class Crysterm::Widget::PlainTextEdit
  def sel_cols(rl)
    selection_columns_for_row(rl)
  end
end

describe "BUGS-F1 #4 triple-click on an empty line plants no dangling anchor" do
  it "leaves the selection anchor nil after triple-clicking an empty LineEdit" do
    s = f1_screen
    le = Widget::LineEdit.new parent: s, left: 0, top: 0, width: 40, height: 1, content: ""
    s._render

    f1_press s, 0, 0
    f1_press s, 0, 0
    f1_press s, 0, 0
    s.click_count.should eq 3

    le.selection_anchor.should be_nil # was 0 (== caret) before the fix
    le.has_selection?.should be_false
  end

  it "keeps every typed character after triple-clicking an empty line" do
    s = f1_screen
    le = Widget::LineEdit.new parent: s, left: 0, top: 0, width: 40, height: 1, content: ""
    s._render

    f1_press s, 0, 0
    f1_press s, 0, 0
    f1_press s, 0, 0

    le._listener f1_key('a')
    le._listener f1_key('b')
    le._listener f1_key('c')
    le.value.should eq "abc" # was "bc" before the fix (each key ate the prior one)
  end
end

describe "BUGS-F1 #5 collapsed selection anchor is cleared so it can't swallow a keystroke" do
  it "Shift+Right then Shift+Left leaves no phantom selection" do
    s = f1_screen
    le = Widget::LineEdit.new parent: s, left: 0, top: 0, width: 40, height: 1, content: "z"
    s._render
    le.cursor_pos = 0

    le._listener f1_ctl(::Tput::Key::ShiftRight)
    le._listener f1_ctl(::Tput::Key::ShiftLeft)
    le.has_selection?.should be_false

    le._listener f1_key('a')
    le._listener f1_key('b')
    le.value.should eq "abz" # was "bz" before the fix (the "a" was silently destroyed)
  end
end

describe "BUGS-F1 #18 reading PlainTextEdit does not double-handle viewer scroll keys" do
  it "viewer_scroll_keys? is true when not reading and false while reading" do
    s = f1_screen
    pte = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 40, height: 5
    pte.value = (0...12).map { |i| "line#{i}" }.join("\n")
    s._render

    pte.viewer_scroll_keys?.should be_true
    pte.focus
    pte.read_input
    pte.viewer_scroll_keys?.should be_false
  end

  it "Down while reading moves only the caret, not the viewport" do
    s = f1_screen
    pte = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 40, height: 5
    pte.value = (0...12).map { |i| "line#{i}" }.join("\n")
    s._render
    pte.focus
    pte.read_input
    pte.cursor_pos = 0
    pte.child_base = 0
    s._render

    # Both the Interactive scroll handler and the TextEditing reading handler
    # are registered; emit through the widget so both would fire.
    pte.emit Crysterm::Event::KeyPress.new('\0', ::Tput::Key::Down)

    # The caret (line 1) is still on screen, so nothing should have scrolled.
    pte.child_base.should eq 0 # was 1 before the fix (Interactive also scrolled)
  end

  it "LineEdit is unaffected (not scrollable)" do
    s = f1_screen
    le = Widget::LineEdit.new parent: s, left: 0, top: 0, width: 40, height: 1, content: "hi"
    s._render
    le.scrollable?.should be_false
  end
end

describe "BUGS-F1 #27 non-wrap caret/selection use full line width, not the viewport slice" do
  it "Up/Down preserves a column that lies beyond the viewport width" do
    s = f1_screen
    pte = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 20, height: 5
    pte.wrap_content = false
    pte.value = ("a" * 100) + "\n" + ("b" * 100)
    s._render

    pte.cursor_pos = 50 # column 50 on line 0 — well past the 20-column viewport
    pte._listener f1_ctl(::Tput::Key::Down)

    # Line 1 starts at index 101; column 50 within it is 151. Before the fix the
    # goal column was clamped to the ~20-wide slice, landing near 121.
    pte.cursor_pos.should eq 151
  end

  it "a selection entirely right of the viewport still yields a highlight range" do
    s = f1_screen
    pte = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 20, height: 5
    pte.wrap_content = false
    pte.value = "a" * 100
    s._render

    pte.selection_anchor = 50
    pte.cursor_pos = 60

    # Before the fix the row's end was computed from the ~20-wide slice, so the
    # 50..60 selection fell entirely past it and returned nil (no highlight).
    pte.sel_cols(0).should_not be_nil
  end
end
