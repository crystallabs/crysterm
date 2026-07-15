require "./spec_helper"

include Crysterm

# Regression specs for the BUGS5 text-editing fixes:
#
#  BUG 1 — The readline kill keys (Ctrl-W / Alt-D / Ctrl-U / Ctrl-K) and the
#    Ctrl-Y yank mutate `@value`/`@cursor_pos` directly (via `kill_backward_to`
#    / `kill_forward_to` / `insert_at_cursor`) without funnelling through
#    `delete_selection`, and they sit in the editing-keys dispatch chain where
#    `moved == false`, so the movement path's `clear_selection if moved &&
#    !extend_sel` never runs either. A stale `@selection_anchor` therefore
#    survived the kill/yank; the *next* keystroke's `delete_selection` then
#    sliced `@value[0...begin] + @value[end..]` with an `end` past the (now
#    shorter) value and raised `IndexError`. Fixed by clearing the selection in
#    all five branches.
#
#  BUG 2 — `LineEdit#_listener` handles Enter / Up / Down with an early `return`
#    that skips `super`, so the mixin's trailing `kill_ring.interrupt if rl &&
#    !killed` never ran for those keys. Two kills straddling a history recall
#    (Ctrl-K, Up, Ctrl-K) wrongly merged into one ring entry. Fixed by calling
#    `kill_ring.interrupt` (gated on `input.readline_keys`) before each return.

private def editor(value : String, pos : Int32)
  s = Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
  le = Widget::LineEdit.new parent: s, top: 0, left: 0, width: 40, height: 1
  le.value = value
  s.render # populate content/cursor geometry so motion keys can resolve
  le.cursor_pos = pos
  le.kill_ring = Crysterm::KillRing.new # isolate from the shared default
  le
end

private def press(le, key : Tput::Key)
  le._listener Crysterm::Event::KeyPress.new('x', key)
end

private def press_char(le, ch : Char)
  le._listener Crysterm::Event::KeyPress.new(ch, nil)
end

describe "BUGS5 stale selection anchor after kill/yank (BUG 1)" do
  it "Ctrl-K clears the selection anchor and a follow-up keystroke does not crash" do
    le = editor "abcdefghij", 2
    le.selection_anchor = 8 # backward drag-selection: anchor after the cursor
    le.selection?.should be_true

    press le, Tput::Key::CtrlK # kill to line end
    le.value.should eq "ab"
    le.selection_anchor.should be_nil
    le.selection?.should be_false

    # Before the fix this ran delete_selection with a stale anchor (8) past the
    # end of the now-2-char value and raised IndexError.
    press_char le, 'X'
    le.value.should eq "abX"
  end

  it "Ctrl-U clears the selection anchor" do
    le = editor "abcdefghij", 8
    le.selection_anchor = 2
    press le, Tput::Key::CtrlU # kill to line start
    le.value.should eq "ij"
    le.selection_anchor.should be_nil
    press_char le, 'X'
    le.value.should_not be_empty
  end

  it "Ctrl-W clears the selection anchor" do
    le = editor "foo bar baz", 7
    le.selection_anchor = 11
    press le, Tput::Key::CtrlW # kill word before cursor
    le.selection_anchor.should be_nil
    press_char le, 'X' # must not raise
  end

  it "Alt-D clears the selection anchor" do
    le = editor "foo bar baz", 4
    le.selection_anchor = 0
    press le, Tput::Key::AltD # kill word after cursor
    le.selection_anchor.should be_nil
    press_char le, 'X' # must not raise
  end

  it "Ctrl-Y clears the selection anchor before yanking" do
    le = editor "abcdefghij", 2
    le.kill_ring.kill "Q" # something to yank
    le.selection_anchor = 8
    press le, Tput::Key::CtrlY
    le.selection_anchor.should be_nil
    press_char le, 'X' # must not raise
  end
end

describe "BUGS5 history keys interrupt the kill run (BUG 2)" do
  it "Up between two kills starts a fresh ring entry instead of merging" do
    le = editor "first", 5
    press le, Tput::Key::Enter # record "first" into history
    le.value = "hello"
    le.cursor_pos = 0

    press le, Tput::Key::CtrlK # kill "hello" -> ring entry #1
    le.value.should eq ""

    press le, Tput::Key::Up # history recall must break the kill run
    le.value.should eq "first"
    le.cursor_pos = 0

    press le, Tput::Key::CtrlK # kill "first" -> ring entry #2 (was merged before fix)
    le.kill_ring.entries.size.should eq 2
    le.kill_ring.entries.should eq ["hello", "first"]
  end

  it "Down also interrupts the kill run" do
    le = editor "abc", 0
    press le, Tput::Key::CtrlK # kill "abc" -> ring entry #1

    # Down on the live line has nothing to recall, but the interrupt must still
    # fire before the early return so the next kill starts a fresh entry.
    press le, Tput::Key::Down

    le.value = "xyz"
    le.cursor_pos = 0
    press le, Tput::Key::CtrlK # new entry (was merged before fix)

    le.kill_ring.entries.size.should eq 2
    le.kill_ring.entries.should eq ["abc", "xyz"]
  end
end
