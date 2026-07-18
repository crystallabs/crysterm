require "./spec_helper"

include Crysterm

# Regression coverage for BUGS15 #86: `Window#focus_pop` must not restore focus
# to a detached/hidden history entry.
#
# `@history` is never pruned on widget removal, so after a subtree is removed
# (without triggering `rewind_focus`, e.g. focus lives outside the removed
# subtree) a stale entry can sit in the history. Popping down onto it must not:
#   * crash — `_focus` walks a detached scrollable ancestor whose `window` is
#     `window?.not_nil!`, raising `NilAssertionError`; nor
#   * hand focus to an off-window widget (state `:focused`, keys routed off the
#     window).
# `focus_pop` now prunes invalid trailing entries with the same predicate as
# `rewind_focus` before restoring focus. Headless, no real terminal.
private def pop_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new)
end

describe "Window#focus_pop with stale history entries" do
  it "does not raise or focus a detached entry when its scrollable ancestor was removed" do
    s = pop_screen
    # Scrollable container A holding focusable input B; C is focusable elsewhere.
    a = Widget::Box.new parent: s, scrollable: true, width: 10, height: 5
    b = Widget::Box.new parent: a, keys: true, width: 5, height: 1
    c = Widget::Box.new parent: s, keys: true, width: 5, height: 1

    s.focus b
    s.focused.should eq b
    s.focus c
    s.focused.should eq c # history is [b, c]

    # Remove A (with B inside). Focus lives on C, outside A, so no rewind runs
    # and stale B lingers in the history; B/A are now detached (window? nil).
    s.remove a
    b.window?.should be_nil
    s.focused.should eq c

    # Popping C exposes detached B on top. Must prune it instead of `_focus`ing
    # it (which would raise on A's detached scrollable ancestor). Nothing valid
    # remains here, so focus clears and C is blurred.
    s.focus_pop.should eq c
    s.focused.should be_nil
    b.state.focused?.should be_false
    c.state.focused?.should be_false
  end

  it "falls back to a still-valid older entry when the top is a detached entry" do
    s = pop_screen
    # D is a valid on-window target that predates the removed subtree.
    d = Widget::Box.new parent: s, keys: true, width: 5, height: 1
    a = Widget::Box.new parent: s, scrollable: true, width: 10, height: 5
    b = Widget::Box.new parent: a, keys: true, width: 5, height: 1
    c = Widget::Box.new parent: s, keys: true, width: 5, height: 1

    s.focus b
    s.focus c # history is [d, b, c]
    s.remove a
    b.window?.should be_nil

    # Pop C, prune detached B, land on still-valid D — no raise, on-window.
    s.focus_pop
    s.focused.should eq d
    d.state.focused?.should be_true
  end

  it "skips a hidden stale entry and restores focus to the next valid one" do
    s = pop_screen
    a = Widget::Box.new parent: s, keys: true, width: 5, height: 1
    b = Widget::Box.new parent: s, keys: true, width: 5, height: 1
    c = Widget::Box.new parent: s, keys: true, width: 5, height: 1

    s.focus b
    s.focus c # history is [a, b, c]

    # Hide B (still attached, but not displayed): it must be skipped on pop.
    b.hide

    s.focus_pop
    s.focused.should eq a
    a.state.focused?.should be_true
  end

  it "leaves normal focus_pop behavior unchanged when all entries are valid" do
    s = pop_screen
    # First keyable widget auto-focuses, seeding the history with a base entry.
    Widget::Box.new parent: s, keys: true, width: 5, height: 1
    b = Widget::Box.new parent: s, keys: true, width: 5, height: 1
    c = Widget::Box.new parent: s, keys: true, width: 5, height: 1

    s.focus b
    s.focus c # history is [<base>, b, c]

    s.focus_pop.should eq c
    s.focused.should eq b
    b.state.focused?.should be_true
  end
end
