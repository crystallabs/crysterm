require "./spec_helper"

include Crysterm

# Reparenting a focused widget between two containers *on the same screen* must
# preserve its keyboard focus. `Widget#remove` (src/widget_children.cr) used to
# `rewind_focus` unconditionally on unlink, popping the still-on-screen widget
# out of the focus history and blurring it. Screen-level `Attach`/`Detach`
# suppression for a same-screen move must likewise leave focus untouched; a
# genuine *cross-screen* move must still rewind.

private def headless_screen
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 20, height: 10)
end

describe "Focus on same-screen reparent" do
  it "keeps focus on a widget moved between containers on one screen" do
    s = headless_screen
    a = Widget::Box.new parent: s, width: "100%", height: "100%"
    b = Widget::Box.new parent: s, width: "100%", height: "100%"
    child = Widget::Box.new width: 4, height: 2, input: true
    a.append child

    child.focus
    s.focused.should eq child

    b.append child # same-screen move

    # Moved, still on the same screen, and still focused.
    child.parent.should eq b
    child.window?.should eq s
    s.focused.should eq child
    child.focused?.should be_true
  end

  it "still rewinds focus off a widget moved to a different screen" do
    s1 = headless_screen
    s2 = headless_screen
    a = Widget::Box.new parent: s1, width: "100%", height: "100%"
    b = Widget::Box.new parent: s2, width: "100%", height: "100%"
    child = Widget::Box.new width: 4, height: 2, input: true
    a.append child

    child.focus
    s1.focused.should eq child

    b.append child # cross-screen move

    # The widget left s1, so s1 must no longer report it as focused.
    child.window?.should eq s2
    s1.focused.should_not eq child
  end
end
