require "./spec_helper"

include Crysterm

private def abr_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

# Renders the screen once headlessly so the bar gets an `@lpos` (its `#current_index=`
# scroll math, and thus the `selected` index, only updates once laid out).
private def abr_render(s)
  s._render
end

# `Mixin::ActionBar#remove_item` (command model behind `Widget::ListBar`,
# `MenuBar`, `ToolBar`) must keep the selection cursor on the same logical
# command when an earlier command is removed: commands at and after the
# deletion shift down by one, so `selected` (= `left_base + left_offset`) must
# slide down too. Mirrors `ItemView#remove_item`. Previously only the
# `i == selected` case was handled, so removing an earlier command left the
# cursor pointing at the wrong command (or past the end).
describe "Mixin::ActionBar#remove_item selection alignment" do
  it "slides the cursor down when an earlier command is removed" do
    s = abr_screen
    bar = Crysterm::Widget::ListBar.new parent: s, width: 80, height: 1
    bar.items = ["a", "b", "c", "d"]
    abr_render s
    bar.current_index = 2 # "c"
    bar.current_index.should eq 2
    bar.item_texts[bar.current_index].should eq "c"

    bar.remove_item bar.items[0] # remove "a"; b,c,d shift to 0,1,2
    bar.items.size.should eq 3
    bar.current_index.should eq 1 # "c" is now at index 1
    bar.item_texts[bar.current_index].should eq "c"
  end

  it "keeps the last selected command valid after removing an earlier one" do
    s = abr_screen
    bar = Crysterm::Widget::ListBar.new parent: s, width: 80, height: 1
    bar.items = ["a", "b", "c"]
    abr_render s
    bar.current_index = 2 # "c" (the last command)
    bar.current_index.should eq 2

    bar.remove_item bar.items[0] # remove "a"; c shifts to index 1
    bar.current_index.should eq 1
    bar.item_texts[bar.current_index].should eq "c"
    bar.items[bar.current_index]?.should_not be_nil
  end

  it "leaves the cursor untouched when a later command is removed" do
    s = abr_screen
    bar = Crysterm::Widget::ListBar.new parent: s, width: 80, height: 1
    bar.items = ["a", "b", "c"]
    abr_render s
    bar.current_index = 0 # "a"
    bar.current_index.should eq 0

    bar.remove_item bar.items[2] # remove "c" (below the cursor)
    bar.current_index.should eq 0
    bar.item_texts[bar.current_index].should eq "a"
  end

  it "still selects the prior command when the selected one itself is removed" do
    s = abr_screen
    bar = Crysterm::Widget::ListBar.new parent: s, width: 80, height: 1
    bar.items = ["a", "b", "c"]
    abr_render s
    bar.current_index = 2 # "c"
    bar.current_index.should eq 2

    bar.remove_item bar.items[2] # remove the selected command
    bar.current_index.should eq 1
    bar.item_texts[bar.current_index].should eq "b"
  end
end
