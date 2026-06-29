require "./spec_helper"

include Crysterm

# Regression coverage for `Window#focus_push` history hygiene (`screen_focus.cr`).
#
# Re-focusing the already-current widget through a screen-level entry point
# (`Window#focus`, or `focus_offset`/Tab wrapping onto the sole focusable widget)
# must NOT stack a duplicate entry onto the focus history. A duplicate top entry
# desyncs the back-stack walk: a later `focus_pop` would pop the duplicate and
# leave focus put instead of returning to the genuine prior widget (and, at
# `focus_history_size`, would rotate a legitimately older entry off the front).
#
# The companion `focus_refocus_emission_spec` covers the *event* side (no
# spurious `Event::Focus` on re-focus); this covers the *history* side. Driven
# headlessly over in-memory IOs; no real terminal is touched.
private def history_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new)
end

describe "Window#focus_push history on re-focus" do
  it "keeps focus_pop anchored to the prior widget after a redundant re-focus" do
    s = history_screen
    # The first focusable widget auto-focuses on insert, so `a` holds focus.
    a = Widget::Box.new parent: s, keys: true
    b = Widget::Box.new parent: s, keys: true
    s.focus b
    s.focused.should eq b

    # Redundant re-focus of the already-current widget: must not push a
    # duplicate `b` onto the history.
    s.focus b
    s.focused.should eq b

    # A single `focus_pop` must rewind to `a` (the genuine prior target). With a
    # stacked duplicate it would pop one `b` and leave focus on `b`.
    s.focus_pop
    s.focused.should eq a
  end

  it "does not stack history when Tab wraps onto the sole focusable widget" do
    s = history_screen
    a = Widget::Box.new parent: s, keys: true
    s.focused.should eq a

    # `focus_offset` resolves the index back onto `a` (it is the only candidate),
    # routing through `focus_push` with `old == el`. With the bug this stacks a
    # second `a`, so the history holds `[a, a]` and a `focus_pop` would re-`_focus`
    # `a` (focus unchanged). With clean history `[a]`, popping the sole entry
    # leaves no prior target, so focus clears.
    s.focus_next
    s.focused.should eq a

    s.focus_pop
    s.focused.should be_nil
  end
end
