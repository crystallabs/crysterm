require "./spec_helper"

include Crysterm

private def sve_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

# `ItemView#selected_values` must report no selection (`[]`, not `[""]`) for an
# empty list. The single-selection branch used to wrap the cached `#value`
# unconditionally, and since `#value` is `""` on an empty list, that surfaced a
# phantom one-element selection — an asymmetry the multi-select branch (which
# already returns `[]`) didn't have.
describe "ItemView#selected_values on an empty list" do
  it "returns [] for an empty single-selection list" do
    s = sve_screen
    list = Crysterm::Widget::List.new parent: s, items: [] of String
    list.items.size.should eq 0
    list.current_text.should eq ""
    list.selected_values.should eq [] of String
  end

  it "returns [] after the last row is removed" do
    s = sve_screen
    list = Crysterm::Widget::List.new parent: s, items: ["a"]
    list.selected_values.should eq ["a"]

    list.remove_item list.item_boxes[0]
    list.items.size.should eq 0
    list.selected_values.should eq [] of String
  end

  it "still reports the selected value for a non-empty list" do
    s = sve_screen
    list = Crysterm::Widget::List.new parent: s, items: ["a", "b", "c"]
    list.current_index = 1
    list.selected_values.should eq ["b"]
  end
end
