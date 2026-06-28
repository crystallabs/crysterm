require "./spec_helper"

include Crysterm

private def sina_screen
  Crysterm::Screen.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

# `ItemView#set_items` must take ownership of its row data rather than aliasing
# the caller's array: the list mutates `@ritems` in place on every
# `append_item`/`insert_item`/`remove_item`, so a stored alias would leak those
# mutations back into the caller's array (and a caller mutating its own array
# afterwards would desync `@ritems` from `@items`).
describe "ItemView#set_items array ownership" do
  it "does not mutate the caller's array when items are appended afterwards" do
    s = sina_screen
    list = Crysterm::Widget::List.new parent: s
    data = ["a", "b", "c"]

    list.set_items data
    list.push_item "d"

    # The list grew, but the caller's array must be untouched.
    list.ritems.should eq ["a", "b", "c", "d"]
    data.should eq ["a", "b", "c"]
  end

  it "is not disturbed by the caller mutating its array afterwards" do
    s = sina_screen
    list = Crysterm::Widget::List.new parent: s
    data = ["x", "y"]

    list.set_items data
    data << "z" # mutate the caller's array

    # The list's own model must stay in sync with its item widgets (size 2).
    list.ritems.should eq ["x", "y"]
    list.items.size.should eq 2
  end
end
