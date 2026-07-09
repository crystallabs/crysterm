require "./spec_helper"

include Crysterm

# Counterpart to `reparent_same_screen_spec.cr`/`reparent_same_screen_focus_spec.cr`
# for a *top-level* widget (direct child of the window, no widget `@parent`).
# `Widget#insert`'s same-window detection used to require `!element.parent.nil?`,
# so pulling a top-level widget into a container on the SAME window took the
# `Window#remove` unlink with no `reparenting_same_screen` suppression:
# window-level `Detach` fired on the whole subtree and `rewind_focus` blurred a
# focused widget — spurious for a pure tree-position change (BUGS12 #17). A
# genuine cross-window move, and a plain `Window#remove`, must keep the full
# detach/rewind behavior.

private def headless_screen
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 20, height: 10)
end

describe "Reparenting a top-level widget within the same window" do
  it "emits no window Detach/Attach when pulled into a container on the same window" do
    s = headless_screen
    container = Widget::Box.new parent: s, width: 10, height: 5
    child = Widget::Box.new parent: s, width: 4, height: 2

    transitions = [] of String
    child.on(Event::Attach) { transitions << "attach" }
    child.on(Event::Detach) { transitions << "detach" }

    container.append child # same-window move, top-level -> nested

    # The widget moved but still derives the same window...
    child.parent.should eq container
    s.children.includes?(child).should be_false
    child.window?.should eq s
    # ...and no window-transition events fired (it never left the window).
    transitions.should be_empty
  end

  it "keeps focus on a focused top-level widget pulled into a container on the same window" do
    s = headless_screen
    container = Widget::Box.new parent: s, width: 10, height: 5
    child = Widget::Box.new parent: s, width: 4, height: 2, input: true

    child.focus
    s.focused.should eq child

    container.append child # same-window move, top-level -> nested

    # Moved, still on the same window, and still focused.
    child.parent.should eq container
    child.window?.should eq s
    s.focused.should eq child
    child.focused?.should be_true
  end

  it "keeps the widget Tab-reachable after the same-window move" do
    s = headless_screen
    container = Widget::Box.new parent: s, width: 10, height: 5
    other = Widget::Box.new parent: s, width: 4, height: 2, input: true
    child = Widget::Box.new parent: s, width: 4, height: 2, input: true

    container.append child

    # `Window#remove` unregistered the subtree on unlink; `Widget#insert` must
    # have re-registered it (`register_subtree`), or Tab could never reach it.
    other.focus
    s.focus_next
    s.focused.should eq child
  end

  it "still emits Detach/Attach when a top-level widget moves into a container on another window" do
    s1 = headless_screen
    s2 = headless_screen
    container = Widget::Box.new parent: s2, width: 10, height: 5
    child = Widget::Box.new parent: s1, width: 4, height: 2

    transitions = [] of String
    child.on(Event::Attach) { transitions << "attach" }
    child.on(Event::Detach) { transitions << "detach" }

    container.append child # cross-window move

    child.window?.should eq s2
    s1.children.includes?(child).should be_false
    transitions.should eq ["detach", "attach"]
  end

  it "still rewinds focus off a focused top-level widget moved to another window" do
    s1 = headless_screen
    s2 = headless_screen
    container = Widget::Box.new parent: s2, width: 10, height: 5
    child = Widget::Box.new parent: s1, width: 4, height: 2, input: true

    child.focus
    s1.focused.should eq child

    container.append child # cross-window move

    # The widget left s1, so s1 must no longer report it as focused.
    child.window?.should eq s2
    s1.focused.should_not eq child
  end

  it "plain Window#remove (no reparent) still emits Detach and rewinds focus" do
    s = headless_screen
    other = Widget::Box.new parent: s, width: 4, height: 2, input: true
    child = Widget::Box.new parent: s, width: 4, height: 2, input: true

    other.focus
    child.focus
    s.focused.should eq child

    detaches = 0
    child.on(Event::Detach) { detaches += 1 }

    s.remove child

    # A genuine removal keeps the full teardown: the subtree is told it left
    # the window, and focus rewinds to the previous valid entry.
    child.window?.should be_nil
    detaches.should eq 1
    s.focused.should eq other
  end
end
