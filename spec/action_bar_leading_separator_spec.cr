require "./spec_helper"

include Crysterm

private def abls_screen
  Crysterm::Window.new(
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

# `Mixin::ActionBar` auto-selects the first command when a bar is built. The
# old `@items.size == 1` guard fired only for the first item added, so a bar
# starting with a separator never auto-selected a real command — `selected`
# stayed stuck on the separator. Fix selects the first *selectable* command
# regardless of how many separators precede it, keeping all commands visible.
describe "Mixin::ActionBar leading-separator auto-selection" do
  it "selects the first real command when the bar opens with a separator" do
    s = abls_screen
    bar = Crysterm::Widget::ListBar.new parent: s, width: 80, height: 1
    bar.items = [separator, Crysterm::Mixin::ActionBar::Command.new("a"),
                 Crysterm::Mixin::ActionBar::Command.new("b")]

    # Lands on the first selectable command (index 1), not the separator.
    bar.current_index.should eq 1
    bar.commands[bar.current_index].separator?.should be_false
    bar.item_texts[bar.current_index].should eq "a"

    # Stays there across a render (separator must not be scrolled off by an
    # inflated left_base).
    s._render
    bar.current_index.should eq 1
    bar.items[0].lpos.should_not be_nil
  end

  it "still selects index 0 for an ordinary leading command" do
    s = abls_screen
    bar = Crysterm::Widget::ListBar.new parent: s, width: 80, height: 1
    bar.items = ["a", "b", "c"]

    bar.current_index.should eq 0
    bar.item_texts[bar.current_index].should eq "a"
  end

  it "does not re-select on a separator added after the first command" do
    s = abls_screen
    bar = Crysterm::Widget::ListBar.new parent: s, width: 80, height: 1
    bar.items = [Crysterm::Mixin::ActionBar::Command.new("a"), separator,
                 Crysterm::Mixin::ActionBar::Command.new("b")]

    bar.current_index.should eq 0
    bar.item_texts[bar.current_index].should eq "a"
  end
end
