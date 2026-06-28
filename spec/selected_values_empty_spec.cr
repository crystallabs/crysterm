require "./spec_helper"

include Crysterm

private def sve_screen
  Crysterm::Screen.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

# `ItemView#selected_values` must report *no* selection for an empty list — an
# empty array, not `[""]`. The single-selection branch used to wrap the cached
# `#value` unconditionally; on an empty list `#value` is correctly `""`, so it
# surfaced a phantom one-element selection. The multi-select branch already
# returns `[]` when nothing is marked, so this also removes that asymmetry.
describe "ItemView#selected_values on an empty list" do
  it "returns [] for an empty single-selection list" do
    s = sve_screen
    list = Crysterm::Widget::List.new parent: s, items: [] of String
    list.items.size.should eq 0
    list.value.should eq ""
    list.selected_values.should eq [] of String
  end

  it "returns [] after the last row is removed" do
    s = sve_screen
    list = Crysterm::Widget::List.new parent: s, items: ["a"]
    list.selected_values.should eq ["a"]

    list.remove_item list.items[0]
    list.items.size.should eq 0
    list.selected_values.should eq [] of String
  end

  it "still reports the selected value for a non-empty list" do
    s = sve_screen
    list = Crysterm::Widget::List.new parent: s, items: ["a", "b", "c"]
    list.selekt 1
    list.selected_values.should eq ["b"]
  end
end
