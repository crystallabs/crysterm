require "./spec_helper"

include Crysterm

# Regression spec: the double-click branch of
# `_setup_text_mouse` seeded `@selection_anchor` at the word bounds
# unconditionally. On non-word text `word_bounds_at` returns an empty
# `{pos, pos}`, leaving a dangling anchor equal to the caret — the exact
# landmine the single-click branch nils out. A later edit shrinks `@value` and
# resurrects the anchor as an out-of-bounds range, crashing `delete_selection`
# with an IndexError. Same headless harness as `text_editing_keys_spec.cr`.

private def new_lineedit(s, content)
  le = Widget::LineEdit.new parent: s, left: 0, top: 0, width: 40, height: 1, content: content
  s.repaint
  le
end

describe "BUGS8 double-click on non-word text leaves no stale selection anchor" do
  it "nils the anchor when the double-clicked position is not a word" do
    s = headless_screen(80, 24, default_quit_keys: true)
    le = new_lineedit s, "ab " # trailing space: position 3 is past the last char

    mouse_down s, 3, 0 # first press
    mouse_down s, 3, 0 # double-click at a non-word (past-end) position

    le.selection?.should be_false
    le.selection_anchor.should be_nil # not a dangling 3 (== caret)
  end

  it "does not crash on a follow-up edit after a non-word double-click" do
    s = headless_screen(80, 24, default_quit_keys: true)
    le = new_lineedit s, "ab "

    mouse_down s, 3, 0
    mouse_down s, 3, 0

    # A stale anchor (3) would turn selection_range into 2...3 once Backspace
    # shrinks the value to "ab"; the next edit then slices "ab"[3..] and raises
    # IndexError. Both edits must be safe.
    le._listener kp('\0', ::Tput::Key::Backspace)
    le.value.should eq "ab"
    le._listener kp('\0', ::Tput::Key::Backspace)
    le.value.should eq "a"
  end

  it "still selects the word on a double-click over word text (no regression)" do
    s = headless_screen(80, 24, default_quit_keys: true)
    le = new_lineedit s, "hello world"

    mouse_down s, 8, 0 # within "world"
    mouse_down s, 8, 0
    s.click_count.should eq 2

    le.selected_text.should eq "world"
    le.selection_range.should eq(6...11)
  end
end
