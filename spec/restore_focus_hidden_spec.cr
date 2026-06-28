require "./spec_helper"

include Crysterm

# `Screen#save_focus`/`#restore_focus` returns focus to a previously-focused
# widget (used by dialogs: `Widget::Message`, `Question`, `Prompt`,
# `FileManager`, `ColorDialog`). The saved widget can still be *attached* to the
# screen yet no longer *displayed* — a container above it was hidden while the
# dialog was up (a switched tab page, a `hide`-n parent). `Widget#focus` does
# not itself gate on visibility, so `restore_focus` must skip a saved widget
# that isn't shown in the tree, exactly as `rewind_focus`/`focus_offset` do.
# Otherwise focus (and the cursor) would land on an off-screen widget.

private def restore_focus_hidden_screen
  Crysterm::Screen.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new)
end

describe "Screen#restore_focus with a hidden saved widget" do
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

    # Hide the container above `a`. `a`'s own `visible?` flag stays true, but it
    # is no longer displayed in the tree. (`a` isn't focused now — `b` is — so
    # this hide does not rewind focus.)
    container.hide
    a.style.visible?.should be_true # own flag still visible, yet not shown in tree

    # No valid prior target is shown, so focus is left as-is (must not move to
    # the off-screen `a`).
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
