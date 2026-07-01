require "./spec_helper"

include Crysterm

private def riss_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

# `ItemView#remove_item` must keep the single-selection cursor on the same
# logical item when an *earlier* row is removed — rows below the deletion
# (including the selected one) shift down by one, so the cursor must slide
# with them. Mirrors the multi-selection-index alignment the method already
# performs. Before the fix `@selected` stayed put, pointing at the wrong item
# or (if selection was the last row) a phantom index past the end.
describe "ItemView#remove_item single-selection cursor alignment" do
  it "slides the cursor down when an earlier row is removed" do
    s = riss_screen
    list = Crysterm::Widget::List.new parent: s, items: ["a", "b", "c", "d"]
    list.selekt 2 # "c"
    list.value.should eq "c"

    list.remove_item list.items[0] # remove "a"; b,c,d shift to 0,1,2
    list.items.size.should eq 3
    list.selected.should eq 1 # "c" is now at index 1
    list.value.should eq "c"  # still tracking the same logical item
  end

  it "keeps the last selected row valid after removing an earlier one" do
    s = riss_screen
    list = Crysterm::Widget::List.new parent: s, items: ["a", "b", "c"]
    list.selekt 2 # "c" (the last row)

    list.remove_item list.items[0] # remove "a"; c shifts to index 1
    list.selected.should eq 1
    list.value.should eq "c"
    # The cursor must point at a real row, not past the end.
    list.items[list.selected]?.should_not be_nil
  end

  it "leaves the cursor untouched when a later row is removed" do
    s = riss_screen
    list = Crysterm::Widget::List.new parent: s, items: ["a", "b", "c"]
    list.selekt 0 # "a"

    list.remove_item list.items[2] # remove "c" (below the cursor)
    list.selected.should eq 0
    list.value.should eq "a"
  end

  it "still selects the prior row when the selected row itself is removed" do
    s = riss_screen
    list = Crysterm::Widget::List.new parent: s, items: ["a", "b", "c"]
    list.selekt 2 # "c"

    list.remove_item list.items[2] # remove the selected row
    list.selected.should eq 1
    list.value.should eq "b"
  end

  it "refreshes value when the selected first row is removed" do
    s = riss_screen
    list = Crysterm::Widget::List.new parent: s, items: ["a", "b", "c"]
    # Cursor stays at index 0 (default selection).
    list.value.should eq "a"

    list.remove_item list.items[0] # remove the selected first row; "b" shifts to 0
    list.items.size.should eq 2
    list.selected.should eq 0 # cursor stays at index 0
    list.value.should eq "b"  # now tracking the row that slid into index 0
  end
end
