require "./spec_helper"

include Crysterm

# BUGS11 #27 — `Colors.safe_convert(String)` (reached via the public, cached
# `Colors.convert_cached`) folds case for named CSS/QSS colors. The shard's
# `ColorNames` table has only lowercase keys, so without folding a capitalized
# keyword (`Red`/`White`) resolves to the `-1` ("terminal default") sentinel.
describe "BUGS11 #27 Colors named-color case folding" do
  it "resolves a capitalized named color the same as its lowercase form" do
    Colors.convert_cached("Red").should eq Colors.convert_cached("red")
    Colors.convert_cached("White").should eq Colors.convert_cached("white")
  end

  it "no longer resolves a capitalized named color to the -1 sentinel" do
    Colors.convert_cached("Red").should_not eq(-1)
    Colors.convert_cached("White").should_not eq(-1)
  end

  it "still parses hex regardless of case (#FF0000 == #ff0000)" do
    Colors.convert_cached("#FF0000").should eq Colors.convert_cached("#ff0000")
    Colors.convert_cached("#FF0000").should eq 0xff0000
  end

  it "still returns -1 for a genuinely unknown color name" do
    Colors.convert_cached("Notacolor").should eq(-1)
    Colors.convert_cached("notacolor").should eq(-1)
  end
end

# BUGS11 #36 — `Mixin::ItemView#create_item` declares no ignored `height`
# parameter (nor a dead `alpha` one): item layout math
# (`#item_row`/`#item_at_row`/`#items_per_page`) assumes single-row items, so
# the created `Box` is fixed at height 1. Omitting the parameter makes it a
# compile-time error for a caller to pass a value that would be silently
# dropped; here we assert the item is actually built 1 row tall.
describe "BUGS11 #36 ItemView#create_item builds 1-high items" do
  it "creates each item Box with height 1" do
    s = headless_screen(80, 24)
    list = Crysterm::Widget::List.new parent: s, items: ["one", "two", "three"]
    list.items.size.should eq 3
    list.item_boxes.each do |item|
      item.height.should eq 1
    end
  end
end
