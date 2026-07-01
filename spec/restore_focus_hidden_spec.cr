require "./spec_helper"

include Crysterm

# `Window#save_focus`/`#restore_focus` returns focus to a previously-focused
# widget (used by dialogs). The saved widget can still be attached to the
# screen yet no longer displayed (a container above it got hidden). `Widget#focus`
# doesn't gate on visibility, so `restore_focus` must skip a saved widget not
# shown in the tree, as `rewind_focus`/`focus_offset` do — else focus (and the
# cursor) lands on an off-screen widget.

private def restore_focus_hidden_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new)
end

describe "Window#restore_focus with a hidden saved widget" do
  it "does not restore focus to a saved widget whose container is hidden" do
    s = restore_focus_hidden_screen
    container = Widget::Box.new parent: s
    a = Widget::Box.new parent: container, keys: true
    b = Widget::Box.new parent: s, keys: true

    a.focus
    s.focused.should eq a
    s.save_focus # remembers `a`
    b.focus
    s.focused.should eq b

    # Hide the container above `a`: `a`'s own `visible?` stays true but it's no
    # longer displayed. (`b` is focused, not `a`, so this doesn't rewind focus.)
    container.hide
    a.style.visible?.should be_true # own flag still visible, yet not shown in tree

    # No valid prior target is shown; must not move to the off-screen `a`.
    s.restore_focus
    s.focused.should eq b
  end

  it "still restores focus to a saved widget that is shown" do
    s = restore_focus_hidden_screen
    container = Widget::Box.new parent: s
    a = Widget::Box.new parent: container, keys: true
    b = Widget::Box.new parent: s, keys: true

    a.focus
    s.save_focus
    b.focus
    s.focused.should eq b

    s.restore_focus
    s.focused.should eq a
  end
end
