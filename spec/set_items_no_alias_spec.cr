require "./spec_helper"

include Crysterm

# `ItemView#set_items` must take ownership of its row data rather than aliasing
# the caller's array: `@ritems` is mutated in place on every
# `add_item`/`insert_item`/`remove_item`, so a stored alias would leak those
# mutations back to the caller (and the caller mutating its array would desync
# `@ritems` from `@items`).
describe "ItemView#set_items array ownership" do
  it "does not mutate the caller's array when items are appended afterwards" do
    s = headless_screen(80, 24)
    list = Crysterm::Widget::List.new parent: s
    data = ["a", "b", "c"]

    list.items = data
    list.add_item "d"

    # List grew, but the caller's array must be untouched.
    list.item_texts.should eq ["a", "b", "c", "d"]
    data.should eq ["a", "b", "c"]
  end

  it "is not disturbed by the caller mutating its array afterwards" do
    s = headless_screen(80, 24)
    list = Crysterm::Widget::List.new parent: s
    data = ["x", "y"]

    list.items = data
    data << "z" # mutate the caller's array

    # List's own model must stay in sync with its item widgets (size 2).
    list.item_texts.should eq ["x", "y"]
    list.items.size.should eq 2
  end
end
