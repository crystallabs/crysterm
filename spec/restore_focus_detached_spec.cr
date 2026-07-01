require "./spec_helper"

include Crysterm

# `Window#save_focus` remembers the focused widget so `#restore_focus` can
# return to it later (used by dialogs: `Widget::Message`, `Question`, `Prompt`,
# `FileManager`, `ColorDialog`). If the saved widget is removed from the screen
# before restore, its `screen` becomes nil. `restore_focus` used to call
# `Widget#focus` unconditionally, dereferencing `screen` (`screen?.not_nil!`)
# and crashing — it must instead skip a saved widget no longer attached.

private def restore_focus_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new)
end

describe "Window#restore_focus" do
  it "does not crash when the saved-focus widget was removed" do
    s = restore_focus_screen
    a = Widget::Box.new parent: s, keys: true
    b = Widget::Box.new parent: s, keys: true

    a.focus
    s.focused.should eq a
    s.save_focus # remembers `a`
    b.focus
    s.focused.should eq b

    s.remove a # `a` is now detached (a.window? is nil)

    # Must not raise; there is no valid prior target, so focus is left as-is.
    s.restore_focus
    s.focused.should eq b
  end

  it "restores focus to the saved widget when it is still attached" do
    s = restore_focus_screen
    a = Widget::Box.new parent: s, keys: true
    b = Widget::Box.new parent: s, keys: true

    a.focus
    s.save_focus # remembers `a`
    b.focus
    s.focused.should eq b

    s.restore_focus
    s.focused.should eq a
  end
end
