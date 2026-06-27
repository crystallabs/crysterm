require "./spec_helper"

include Crysterm

# `Screen#save_focus` remembers the currently-focused widget so a later
# `#restore_focus` can return focus to it (used by dialogs: `Widget::Message`,
# `Question`, `Prompt`, `FileManager`, `ColorDialog`). If that saved widget is
# *removed* from the screen before focus is restored — e.g. the dialog outlives
# the widget it saved — the widget's `screen` becomes nil. `restore_focus` used
# to call `Widget#focus` unconditionally, which dereferences `screen`
# (`screen?.not_nil!`) and crashes. It must instead skip a saved widget that is
# no longer attached to this screen.

private def restore_focus_screen
  Crysterm::Screen.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new)
end

describe "Screen#restore_focus" do
  it "does not crash when the saved-focus widget was removed" do
    s = restore_focus_screen
    a = Widget::Box.new parent: s, keys: true
    b = Widget::Box.new parent: s, keys: true

    a.focus
    s.focused.should eq a
    s.save_focus # remembers `a`
    b.focus
    s.focused.should eq b

    s.remove a # `a` is now detached (a.screen? is nil)

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
