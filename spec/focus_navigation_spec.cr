require "./spec_helper"

include Crysterm

# Keyboard focus navigation (`Screen#focus_offset` and friends). Driven
# headlessly over in-memory IOs; no real terminal is touched.

private def focus_screen
  Crysterm::Screen.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new)
end

describe "Screen#focus_offset" do
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

  # Regression: `@keyable` is not pruned when a widget is removed, so it can hold
  # detached widgets (whose `@screen` is nil). `focus_offset` must treat those as
  # "not attached" via `screen?` rather than crashing on the raising `screen`.
  it "does not crash when a removed widget lingers in the keyable list" do
    s = focus_screen
    a = Widget::Box.new parent: s, keys: true
    stale = Widget::Box.new parent: s, keys: true
    b = Widget::Box.new parent: s, keys: true

    a.focus
    s.remove stale # stale stays registered in @keyable but is now detached

    s.focus_next # would raise NilAssertionError before the fix
    s.focused.should_not be_nil
    s.focused.should_not eq stale
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

describe "Screen#focus (re-focus of the already-focused widget)" do
  # Regression: `Screen#focus` (and `focus_offset`, e.g. Tab wrapping back onto
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

describe "Screen#rewind_focus" do
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
end
