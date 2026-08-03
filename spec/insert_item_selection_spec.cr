require "./spec_helper"

include Crysterm

# `ItemView#insert_item` must keep the single-selection cursor on the same
# logical item when a row is inserted at or before it: every row from the
# insertion point onward (including the selected one) shifts down by one, and
# the cursor must slide with them. Mirrors the multi-selection-index alignment
# the method already performs (`s >= i`); inverse of `remove_item`'s cursor
# realignment. Guards the case of an insert *before* the cursor (not just at it)
# leaving `@selected` pointing at the wrong item with `@value` stale.
describe "ItemView#insert_item single-selection cursor alignment" do
  it "slides the cursor down when an earlier row is inserted" do
    s = headless_screen(80, 24)
    list = Crysterm::Widget::List.new parent: s, items: ["a", "b", "c", "d"]
    list.current_index = 2 # "c"
    list.current_text.should eq "c"

    list.insert_item 0, "x" # x,a,b,c,d : "c" moves to index 3
    list.items.size.should eq 5
    list.current_index.should eq 3
    list.current_text.should eq "c" # still tracking the same logical item
  end

  it "slides the cursor down when a row is inserted exactly at the cursor" do
    s = headless_screen(80, 24)
    list = Crysterm::Widget::List.new parent: s, items: ["a", "b", "c"]
    list.current_index = 1 # "b"

    list.insert_item 1, "x" # a,x,b,c : "b" moves to index 2
    list.current_index.should eq 2
    list.current_text.should eq "b"
  end

  it "leaves the cursor untouched when a later row is inserted" do
    s = headless_screen(80, 24)
    list = Crysterm::Widget::List.new parent: s, items: ["a", "b", "c"]
    list.current_index = 0 # "a"

    list.insert_item 2, "x" # a,b,x,c : cursor stays on "a"
    list.current_index.should eq 0
    list.current_text.should eq "a"
  end
end
