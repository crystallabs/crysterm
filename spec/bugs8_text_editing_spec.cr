require "./spec_helper"

include Crysterm

# Regression spec for the BUGS8 text-editing fix: the double-click branch of
# `_setup_text_mouse` seeded `@selection_anchor` at the word bounds
# unconditionally. On non-word text `word_bounds_at` returns an empty
# `{pos, pos}`, so it left a dangling anchor equal to the caret — the exact
# landmine the single-click branch nils out. A later edit shrinks `@value` and
# resurrects the anchor as an out-of-bounds range, crashing `delete_selection`
# with an IndexError. Same headless harness as `text_editing_keys_spec.cr`.

private def sel_screen
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 80, height: 24)
end

private def mouse(action, x, y, button = ::Tput::Mouse::Button::Left)
  ::Tput::Mouse::Event.new(action, button, x, y, source: :test)
end

private def press(s, x, y)
  s.dispatch_mouse mouse(::Tput::Mouse::Action::Down, x, y)
end

private def new_lineedit(s, content)
  le = Widget::LineEdit.new parent: s, left: 0, top: 0, width: 40, height: 1, content: content
  s._render
  le
end

describe "BUGS8 double-click on non-word text leaves no stale selection anchor" do
  it "nils the anchor when the double-clicked position is not a word" do
    s = sel_screen
    le = new_lineedit s, "ab " # trailing space: position 3 is past the last char

    press s, 3, 0 # first press
    press s, 3, 0 # double-click at a non-word (past-end) position

    le.selection?.should be_false
    le.selection_anchor.should be_nil # would be 3 (== caret) before the fix
  end

  it "does not crash on a follow-up edit after a non-word double-click" do
    s = sel_screen
    le = new_lineedit s, "ab "

    press s, 3, 0
    press s, 3, 0

    # Before the fix: Backspace shrinks the value to "ab" while the stale anchor
    # (3) turns selection_range into 2...3; the next edit slices "ab"[3..] and
    # raises IndexError. Must be safe now.
    le._listener Crysterm::Event::KeyPress.new('\0', ::Tput::Key::Backspace)
    le.value.should eq "ab"
    le._listener Crysterm::Event::KeyPress.new('\0', ::Tput::Key::Backspace)
    le.value.should eq "a"
  end

  it "still selects the word on a double-click over word text (no regression)" do
    s = sel_screen
    le = new_lineedit s, "hello world"

    press s, 8, 0 # within "world"
    press s, 8, 0
    s.click_count.should eq 2

    le.selected_text.should eq "world"
    le.selection_range.should eq(6...11)
  end
end
