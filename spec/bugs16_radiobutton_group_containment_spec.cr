require "./spec_helper"

include Crysterm

# B16-30: RadioButton#on_statechanged unchecked EVERY descendant RadioButton
# under the containing widget-tree ancestor, ignoring `ButtonGroup` membership.
# Two exclusive `ButtonGroup`s whose radios share one parent container (e.g.
# a `Box` holding two radio questions, a common layout-engine arrangement)
# interfered: checking a radio in one group unchecked the checked radio of the
# *other* group, and the cascade even defeated the other group's "never leave
# nothing selected" revert (its suppressed re-check re-emits StateChanged,
# re-running the containment handler while @suppress is raised).
#
# Fix: RadioButton#on_statechanged now defers entirely to its `ButtonGroup`
# (the `group` back-reference) when one owns the button -- matching Qt, where
# per-parent autoExclusive behavior applies only to ungrouped radios.

private def add_mem_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24)
end

describe Crysterm::Widget::RadioButton do
  it "does not let containment-based exclusivity cross ButtonGroup boundaries" do
    s = add_mem_screen
    box = Widget::Box.new parent: s

    r1a = Widget::RadioButton.new parent: box
    r1b = Widget::RadioButton.new parent: box
    r2a = Widget::RadioButton.new parent: box
    r2b = Widget::RadioButton.new parent: box

    g1 = ButtonGroup.new
    g1.add_button r1a
    g1.add_button r1b

    g2 = ButtonGroup.new
    g2.add_button r2a
    g2.add_button r2b

    # Answer question 2 first.
    r2a.check
    g2.checked_button.should eq r2a

    # Answer question 1: r1a's containment handler must not reach into g2's
    # radios, even though they share the same parent `box`.
    r1a.check

    g1.checked_button.should eq r1a
    r2a.checked?.should be_true
    g2.checked_button.should eq r2a
  end

  it "still applies containment exclusivity to ungrouped radios sharing a parent" do
    s = add_mem_screen
    box = Widget::Box.new parent: s

    r1 = Widget::RadioButton.new parent: box
    r2 = Widget::RadioButton.new parent: box

    r1.check
    r1.checked?.should be_true
    r2.checked?.should be_false

    r2.check
    r2.checked?.should be_true
    r1.checked?.should be_false
  end
end
