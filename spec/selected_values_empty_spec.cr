require "./spec_helper"

include Crysterm

# `ItemView#selected_values` must report no selection (`[]`, not `[""]`) for an
# empty list. Wrapping the cached `#value` unconditionally would surface a
# phantom one-element selection, since `#value` is `""` on an empty list — an
# asymmetry the multi-select branch (which returns `[]`) doesn't have.
describe "ItemView#selected_values on an empty list" do
  it "returns [] for an empty single-selection list" do
    s = headless_screen(80, 24)
    list = Crysterm::Widget::List.new parent: s, items: [] of String
    list.items.size.should eq 0
    list.current_text.should eq ""
    list.selected_values.should eq [] of String
  end

  it "returns [] after the last row is removed" do
    s = headless_screen(80, 24)
    list = Crysterm::Widget::List.new parent: s, items: ["a"]
    list.selected_values.should eq ["a"]

    list.remove_item list.item_boxes[0]
    list.items.size.should eq 0
    list.selected_values.should eq [] of String
  end

  it "still reports the selected value for a non-empty list" do
    s = headless_screen(80, 24)
    list = Crysterm::Widget::List.new parent: s, items: ["a", "b", "c"]
    list.current_index = 1
    list.selected_values.should eq ["b"]
  end
end
