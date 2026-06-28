require "./spec_helper"

include Crysterm

private def abst_screen
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

# `Mixin::ActionBar` keeps the selection highlight off non-selectable separators
# everywhere — `#add` (leading-separator auto-select), `#remove_item` (via
# `#nearest_selectable`) and `#move` (separator-stepping). `#select_tab`, reached
# both directly and by the `auto_command_keys` number keys (`select_tab i`), was
# the one path that did not: selecting a separator's index settled the cursor on
# it (a dead Enter target) and fired its nil callback. It now treats a separator
# index like an out-of-range one — a no-op.
describe "Mixin::ActionBar#select_tab separator guard" do
  it "is a no-op when the target tab is a separator" do
    s = abst_screen
    bar = Crysterm::Widget::ListBar.new parent: s, width: 80, height: 1
    bar.set_items [Crysterm::Mixin::ActionBar::Command.new("a"), separator,
                   Crysterm::Mixin::ActionBar::Command.new("b")]

    # Lay the bar out so `#selekt`'s scroll math (gated on a real `@lpos`) is
    # live; otherwise selecting an index can't move `selected` at all.
    s._render
    bar.selected.should eq 0 # the first real command

    # Selecting the separator at index 1 must not move the cursor onto it...
    bar.select_tab 1
    bar.selected.should eq 0
    bar.commands[bar.selected].separator?.should be_false
    # ...nor highlight the separator's own item box.
    bar.items[1].state.selected?.should be_false

    # A real tab still selects normally.
    bar.select_tab 2
    bar.selected.should eq 2
    bar.ritems[bar.selected].should eq "b"
  end
end
