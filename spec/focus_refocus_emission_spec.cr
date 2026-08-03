require "./spec_helper"

include Crysterm

# Regression coverage for `Window#_focus` (`window_focus.cr`).
#
# `Event::FocusIn` denotes a focus *change* and must fire exactly once, when focus
# actually moves. Re-focusing the already-focused widget through a screen-level
# entry point (`Window#focus`, or `focus_offset`/Tab wrapping onto the sole
# focusable widget) routes straight to `_focus el, el`. The `old == cur` handling
# suppresses the spurious `FocusOut` and state clobber, and must also suppress
# the terminating `Event::FocusIn` — else it re-runs focus side effects on a
# widget already focused (same family of defect `window_rendering.cr#repaint`
# guards against per frame).
describe "Window#_focus re-focus emission" do
  it "emits Event::FocusIn once on a real change but not on re-focus" do
    s = headless_screen(default_quit_keys: true)
    # First focusable widget auto-focuses on insert (see
    # `insert_chrome_focus_spec`), so `a` already holds focus. Add a second
    # to observe a genuine focus *move* onto it.
    a = Widget::Box.new parent: s, keys: true
    b = Widget::Box.new parent: s, keys: true
    s.focused.should eq a

    focus_events = 0
    b.on(Crysterm::Event::FocusIn) { focus_events += 1 }

    # A genuine focus change (a -> b): emits exactly once.
    s.focus b
    s.focused.should eq b
    focus_events.should eq 1

    # Re-focusing via the screen-level entry point is not a focus change: no
    # further Event::FocusIn.
    s.focus b
    s.focused.should eq b
    focus_events.should eq 1
  end

  it "does not emit Event::FocusIn when Tab wraps onto the sole focusable widget" do
    s = headless_screen(default_quit_keys: true)
    a = Widget::Box.new parent: s, keys: true

    a.focus
    s.focused.should eq a

    focus_events = 0
    a.on(Crysterm::Event::FocusIn) { focus_events += 1 }

    # With a single focusable widget, `focus_next` wraps the index back onto it.
    s.focus_next
    s.focused.should eq a
    focus_events.should eq 0
  end
end
