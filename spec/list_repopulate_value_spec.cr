require "./spec_helper"

include Crysterm

private def lrv_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

# `ItemView#select_index` latches `@_list_initialized` so the first selection of index
# 0 runs even though `@selected` is already 0. Emptying the list must clear that
# latch, or re-populating lands on the unchanged-index short-circuit
# (`@selected == 0 && @_list_initialized`): the new row renders selected but
# `#value` stays stale and no `ItemSelected` fires.
describe "ItemView#select_index value after re-populating an emptied list" do
  it "refreshes #value when the first row is appended to an emptied list" do
    s = lrv_screen
    list = Crysterm::Widget::List.new parent: s, items: ["a", "b"]
    list.select_index 1
    list.current_text.should eq "b"

    # Second removal takes it through the empty-selection branch of `#select_index`.
    list.remove_item list.items[1]
    list.remove_item list.items[0]
    list.items.size.should eq 0
    list.current_text.should eq ""

    # New first row is selected, so `value` must track it.
    list.add_item "z"
    list.current_index.should eq 0
    list.current_text.should eq "z"
  end

  it "refreshes #value after the list is emptied via clear" do
    s = lrv_screen
    list = Crysterm::Widget::List.new parent: s, items: ["a", "b"]
    list.select_index 1
    list.current_text.should eq "b"

    list.clear # set_items [] -> empty-selection branch
    list.items.size.should eq 0
    list.current_text.should eq ""

    list.add_item "z"
    list.current_index.should eq 0
    list.current_text.should eq "z"
  end
end
