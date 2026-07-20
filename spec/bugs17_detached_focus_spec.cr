require "./spec_helper"

include Crysterm

# B17-07: `Widget#focus` must no-op on a detached widget (removed from its
# tree, holding no `@window`), just like its siblings `#grab_mouse` /
# `#grab_keyboard` / `#release_mouse` / `#release_keyboard` / `#clear_focus`.
# The old `return if focused?; window.focus self` fell through to the
# raising `#window` accessor and crashed with `NilAssertionError`.

private def detached_focus_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new)
end

describe "Widget#focus" do
  it "no-ops (does not raise) on a detached widget" do
    s = detached_focus_screen
    w = Widget::Box.new parent: s, keys: true

    s.remove w
    w.window?.should be_nil
    w.focused?.should be_false

    w.focus

    w.window?.should be_nil
    w.focused?.should be_false
  end
end
