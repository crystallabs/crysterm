require "./spec_helper"

include Crysterm

# Keyboard focus navigation (`Window#focus_offset` and friends). Driven
# headlessly over in-memory IOs; no real terminal is touched.

private def focus_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new)
end

describe "Window#focus_offset" do
  it "moves focus between attached keyable widgets" do
    s = focus_screen
    a = Widget::Box.new parent: s, keys: true
    b = Widget::Box.new parent: s, keys: true

    a.focus
    s.focused.should eq a
    s.focus_next
    s.focused.should eq b
    s.focus_previous
    s.focused.should eq a
  end

  # Regression: from a no-focus state (reachable once focus has been cleared —
  # e.g. the focused widget was removed, or the history emptied), navigation
  # must enter from the natural end: `focus_next` onto the FIRST focusable
  # widget and `focus_previous` onto the LAST. The old `-1` sentinel only got
  # the forward case right; `focus_previous` landed mid-list (second-from-last,
  # or with two widgets the first) instead of the last.
  it "enters from the correct end when nothing is focused" do
    s = focus_screen
    a = Widget::Box.new parent: s, keys: true
    Widget::Box.new parent: s, keys: true
    c = Widget::Box.new parent: s, keys: true

    # Adding the first keyable widget auto-focuses it; clear back to no focus.
    s.@history.clear
    s.focused.should be_nil
    s.focus_next # no focus -> first focusable
    s.focused.should eq a

    # Reset to "no focus" and go the other way -> last focusable.
    s.@history.clear
    s.focused.should be_nil
    s.focus_previous
    s.focused.should eq c
  end

  # Regression: `@keyable` is not pruned when a widget is removed, so it can hold
  # detached widgets (whose `@screen` is nil). `focus_offset` must treat those as
  # "not attached" via `screen?` rather than crashing on the raising `screen`.
  it "does not crash when a removed widget lingers in the keyable list" do
    s = focus_screen
    a = Widget::Box.new parent: s, keys: true
    stale = Widget::Box.new parent: s, keys: true
    Widget::Box.new parent: s, keys: true

    a.focus
    s.remove stale # stale stays registered in @keyable but is now detached

    s.focus_next # would raise NilAssertionError before the fix
    s.focused.should_not be_nil
    s.focused.should_not eq stale
  end

  # Regression: a disabled widget does not react to keyboard input, so Tab /
  # Shift+Tab navigation must step over it — focus must never land on a dead
  # widget. (Landing on it would also route through `_focus`, which sets
  # `state = :focused` and would silently clear the `Disabled` state.)
  it "skips a disabled keyable widget" do
    s = focus_screen
    a = Widget::Box.new parent: s, keys: true
    b = Widget::Box.new parent: s, keys: true
    c = Widget::Box.new parent: s, keys: true

    b.state = Crysterm::WidgetState::Disabled

    a.focus
    s.focused.should eq a
    s.focus_next # must skip the disabled `b` and land on `c`
    s.focused.should eq c
    s.focused.should_not eq b
    # `b` is still disabled — navigation did not focus (and thereby un-disable) it.
    b.disabled?.should be_true

    # And backward navigation skips it too: from `c`, `focus_previous` lands on
    # `a`, not the disabled `b`.
    s.focus_previous
    s.focused.should eq a
  end

  # When the only keyable widget is disabled there is no valid target, so
  # navigation is a no-op rather than focusing it (or looping forever).
  it "does not focus the sole keyable widget when it is disabled" do
    s = focus_screen
    a = Widget::Box.new parent: s, keys: true
    a.state = Crysterm::WidgetState::Disabled
    s.@history.clear

    s.focus_next
    s.focused.should be_nil
  end

  # Regression: `@keyable` is not pruned when a widget is removed, so after a
  # widget is MOVED from one screen to another it lingers in the old screen's
  # `@keyable` — now with `screen?` pointing at the NEW screen. A bare truthy
  # `screen?` guard would accept it, so Tab on the old screen could focus a
  # widget that now lives on a different screen. The guard must require
  # attachment to THIS screen (`screen? == self`).
  it "does not focus a widget that was moved to another screen" do
    s1 = focus_screen
    s2 = focus_screen
    a = Widget::Box.new parent: s1, keys: true
    b = Widget::Box.new parent: s1, keys: true

    a.focus
    s1.focused.should eq a

    # Move `b` to the other screen. It stays registered in `s1.@keyable` (not
    # pruned) but now belongs to `s2`.
    s1.remove b
    s2.append b
    b.window?.should eq s2

    # `a` is the only widget still on `s1`; navigation must stay on it and never
    # jump onto `b` (which lives on `s2`).
    s1.focus_next
    s1.focused.should eq a
    s1.focused.should_not eq b
  end

  # Regression: focus-candidate selection must be ancestor-aware. A keyable
  # widget whose own `style.visible?` is still true but whose container is
  # hidden is not actually on screen, so navigation must skip over it instead of
  # landing focus inside an invisible subtree.
  it "skips a keyable widget whose ancestor is hidden" do
    s = focus_screen
    a = Widget::Box.new parent: s, keys: true
    container = Widget::Box.new parent: s
    inner = Widget::Box.new parent: container, keys: true
    b = Widget::Box.new parent: s, keys: true

    container.hide # inner stays flagged visible, but its parent is hidden

    a.focus
    s.focused.should eq a
    s.focus_next # must skip `inner` (hidden ancestor) and land on `b`
    s.focused.should eq b
    s.focused.should_not eq inner
  end
end

describe "Window#focus (re-focus of the already-focused widget)" do
  # Regression: `Window#focus` (and `focus_offset`, e.g. Tab wrapping back onto
  # the sole focusable widget) routes straight to `_focus el, el`. The state
  # assignment used to set `:focused` (a no-op) then `:normal`, clobbering the
  # highlight — and emit a spurious `Blur` on the widget being focused.
  it "keeps the widget focused and emits no Blur on itself" do
    s = focus_screen
    a = Widget::Box.new parent: s, keys: true

    s.focus a
    a.state.should eq Crysterm::WidgetState::Focused

    blurs = 0
    a.on(Crysterm::Event::Blur) { blurs += 1 }

    s.focus a # re-focus the already-focused widget (screen-level entry point)

    a.state.should eq Crysterm::WidgetState::Focused
    blurs.should eq 0
  end

  # The same hazard via keyboard navigation: with a single focusable widget,
  # `focus_next` wraps the index back onto it, re-focusing it.
  it "leaves the sole focusable widget focused after Tab wraps onto it" do
    s = focus_screen
    a = Widget::Box.new parent: s, keys: true

    a.focus
    s.focus_next # wraps back to `a`
    s.focused.should eq a
    a.state.should eq Crysterm::WidgetState::Focused
  end
end

describe "Window#rewind_focus" do
  # Regression: `_focus` already emits `Event::Blur` on the previously-focused
  # widget, so `rewind_focus` must NOT emit it a second time. It used to, leaving
  # the blurred widget with a double Blur.
  it "emits Blur on the old widget exactly once" do
    s = focus_screen
    a = Widget::Box.new parent: s, keys: true
    b = Widget::Box.new parent: s, keys: true

    a.focus
    b.focus
    s.focused.should eq b

    blurs = 0
    b.on(Crysterm::Event::Blur) { blurs += 1 }

    s.rewind_focus

    blurs.should eq 1
  end

  # Regression (deferred): when no valid prior target remains — the focused
  # widget was hidden/removed and nothing earlier in the history is still
  # attached and visible — `rewind_focus` must fully *clear* focus: `focused`
  # becomes nil AND the previously-focused widget is blurred (its `:focused`
  # state dropped and an `Event::Blur` emitted), instead of lingering in
  # `WidgetState::Focused` with no Blur ever fired.
  it "blurs and clears focus when no valid prior target remains" do
    s = focus_screen
    a = Widget::Box.new parent: s, keys: true

    a.focus
    s.focused.should eq a
    a.state.should eq Crysterm::WidgetState::Focused

    blurs = 0
    a.on(Crysterm::Event::Blur) { blurs += 1 }

    a.hide # the sole focusable widget; nothing valid to rewind to

    s.focused.should be_nil
    a.state.should_not eq Crysterm::WidgetState::Focused
    blurs.should eq 1
  end
end
