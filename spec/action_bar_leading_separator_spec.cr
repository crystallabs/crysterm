require "./spec_helper"

include Crysterm

private def abls_screen
  Crysterm::Screen.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

private def separator(text = "|")
  cmd = Crysterm::Mixin::ActionBar::Command.new text
  cmd.separator = true
  cmd
end

# `Mixin::ActionBar` (the command model behind `Widget::ListBar`, `MenuBar`,
# `ToolBar`) auto-selects the first command when a bar is built. The old
# `@items.size == 1` guard fired only for the very first item added, so a bar
# whose first item was a non-selectable separator (a leading `add_separator`)
# never auto-selected its first real command: `selected` (and the focus
# highlight / Enter target) stayed stuck on the separator. The fix selects the
# first *selectable* command regardless of how many separators precede it,
# while keeping every command — separators included — visible.
describe "Mixin::ActionBar leading-separator auto-selection" do
  it "selects the first real command when the bar opens with a separator" do
    s = abls_screen
    bar = Crysterm::Widget::ListBar.new parent: s, width: 80, height: 1
    bar.set_items [separator, Crysterm::Mixin::ActionBar::Command.new("a"),
                   Crysterm::Mixin::ActionBar::Command.new("b")]

    # Selection lands on the first selectable command (index 1), not the
    # separator at index 0.
    bar.selected.should eq 1
    bar.commands[bar.selected].separator?.should be_false
    bar.ritems[bar.selected].should eq "a"

    # And it stays there across a render (the separator must remain visible —
    # i.e. not scrolled off by an inflated left_base).
    s._render
    bar.selected.should eq 1
    bar.items[0].lpos.should_not be_nil
  end

  it "still selects index 0 for an ordinary leading command" do
    s = abls_screen
    bar = Crysterm::Widget::ListBar.new parent: s, width: 80, height: 1
    bar.set_items ["a", "b", "c"]

    bar.selected.should eq 0
    bar.ritems[bar.selected].should eq "a"
  end

  it "does not re-select on a separator added after the first command" do
    s = abls_screen
    bar = Crysterm::Widget::ListBar.new parent: s, width: 80, height: 1
    bar.set_items [Crysterm::Mixin::ActionBar::Command.new("a"), separator,
                   Crysterm::Mixin::ActionBar::Command.new("b")]

    bar.selected.should eq 0
    bar.ritems[bar.selected].should eq "a"
  end
end
