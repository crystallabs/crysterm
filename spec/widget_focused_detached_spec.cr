require "./spec_helper"

include Crysterm

# `Widget#focused?` must answer for any widget, including a detached one
# (removed from its screen, holding no `@screen` and deriving none through a
# parent). It must consult the non-raising `#screen?` and report `false`
# rather than crash with `NilAssertionError` (what the old raising `#screen`
# produced).

private def detached_focus_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new)
end

describe "Widget#focused?" do
  it "reflects focus state while attached" do
    s = detached_focus_screen
    a = Widget::Box.new parent: s, keys: true
    b = Widget::Box.new parent: s, keys: true

    a.focus
    a.focused?.should be_true
    b.focused?.should be_false
  end

  it "returns false (does not raise) for a detached widget" do
    s = detached_focus_screen
    Widget::Box.new parent: s, keys: true
    w = Widget::Box.new parent: s, keys: true

    w.focus
    w.focused?.should be_true

    # Detach from the screen; focus rewinds to `other`. Querying the
    # screen-less widget must answer `false`, not crash.
    s.remove w
    w.window?.should be_nil
    w.focused?.should be_false
  end
end
