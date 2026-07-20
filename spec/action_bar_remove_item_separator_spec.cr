require "./spec_helper"

include Crysterm

private def abrs_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

# Renders once so the bar gets an `@lpos` (`#current_index=` scroll math, and thus
# `selected`, only updates once laid out).
private def abrs_render(s)
  s.repaint
end

# `Mixin::ActionBar#remove_item` realigns the selection cursor on removal, but
# must keep it off non-selectable separators, like `#move`/`#add` already do.
# Removing the selected command when its prior neighbor is a separator used to
# land the highlight there — a dead cursor whose Enter does nothing.
describe "Mixin::ActionBar#remove_item separator skipping" do
  it "skips back over a separator when the selected command is removed" do
    s = abrs_screen
    bar = Crysterm::Widget::ListBar.new parent: s, width: 80, height: 1
    bar.add_item "a"
    bar.add_separator
    bar.add_item "b"
    abrs_render s

    bar.current_index = 2 # "b"
    bar.current_index.should eq 2
    bar.item_texts[bar.current_index].should eq "b"

    bar.remove_item bar.item_boxes[2] # remove the selected "b"
    # Prior command is the separator at index 1; cursor must skip back to the
    # selectable "a" rather than settle on the separator.
    bar.current_index.should eq 0
    bar.commands[bar.current_index].separator?.should be_false
    bar.item_texts[bar.current_index].should eq "a"
  end

  it "falls forward to the next selectable command when only separators precede" do
    s = abrs_screen
    bar = Crysterm::Widget::ListBar.new parent: s, width: 80, height: 1
    bar.add_separator
    bar.add_item "a" # first selectable (auto-selected)
    bar.add_item "b"
    abrs_render s

    bar.current_index = 1 # "a"
    bar.current_index.should eq 1

    bar.remove_item bar.item_boxes[1] # remove the selected "a"
    # Index 0 (now-only-preceding) is a separator with nothing selectable
    # before it, so cursor falls forward to "b".
    bar.commands[bar.current_index].separator?.should be_false
    bar.item_texts[bar.current_index].should eq "b"
  end
end
