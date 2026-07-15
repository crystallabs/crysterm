require "./spec_helper"

include Crysterm

private def iiss_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

# `ItemView#insert_item` must keep the single-selection cursor on the same
# logical item when a row is inserted at or before it: every row from the
# insertion point onward (including the selected one) shifts down by one, and
# the cursor must slide with them. Mirrors the multi-selection-index alignment
# the method already performs (`s >= i`); inverse of `remove_item`'s cursor
# realignment. Previously only an insert exactly at the cursor was handled; an
# insert before it left `@selected` pointing at the wrong item with `@value` stale.
describe "ItemView#insert_item single-selection cursor alignment" do
  it "slides the cursor down when an earlier row is inserted" do
    s = iiss_screen
    list = Crysterm::Widget::List.new parent: s, items: ["a", "b", "c", "d"]
    list.select_index 2 # "c"
    list.value.should eq "c"

    list.insert_item 0, "x" # x,a,b,c,d : "c" moves to index 3
    list.items.size.should eq 5
    list.selected.should eq 3
    list.value.should eq "c" # still tracking the same logical item
  end

  it "slides the cursor down when a row is inserted exactly at the cursor" do
    s = iiss_screen
    list = Crysterm::Widget::List.new parent: s, items: ["a", "b", "c"]
    list.select_index 1 # "b"

    list.insert_item 1, "x" # a,x,b,c : "b" moves to index 2
    list.selected.should eq 2
    list.value.should eq "b"
  end

  it "leaves the cursor untouched when a later row is inserted" do
    s = iiss_screen
    list = Crysterm::Widget::List.new parent: s, items: ["a", "b", "c"]
    list.select_index 0 # "a"

    list.insert_item 2, "x" # a,b,x,c : cursor stays on "a"
    list.selected.should eq 0
    list.value.should eq "a"
  end
end
