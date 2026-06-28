require "./spec_helper"

include Crysterm

private def lrv_screen
  Crysterm::Screen.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

# `ItemView#selekt` latches `@_list_initialized` so the very first selection of
# index 0 runs even though `@selected` is already 0. Emptying the list must
# clear that latch: otherwise re-populating an emptied list lands on the
# unchanged-index short-circuit (`@selected == 0 && @_list_initialized`) and the
# first new row is rendered selected while the cached `#value` stays stale (and
# no `SelectItem` fires).
describe "ItemView#selekt value after re-populating an emptied list" do
  it "refreshes #value when the first row is appended to an emptied list" do
    s = lrv_screen
    list = Crysterm::Widget::List.new parent: s, items: ["a", "b"]
    list.selekt 1
    list.value.should eq "b"

    # Empty the list entirely (the second removal takes it through the
    # empty-selection branch of `#selekt`).
    list.remove_item list.items[1]
    list.remove_item list.items[0]
    list.items.size.should eq 0
    list.value.should eq ""

    # Re-populate: the new first row is selected, so `value` must track it.
    list.append_item "z"
    list.selected.should eq 0
    list.value.should eq "z"
  end

  it "refreshes #value after the list is emptied via clear_items" do
    s = lrv_screen
    list = Crysterm::Widget::List.new parent: s, items: ["a", "b"]
    list.selekt 1
    list.value.should eq "b"

    list.clear_items # set_items [] -> empty-selection branch
    list.items.size.should eq 0
    list.value.should eq ""

    list.append_item "z"
    list.selected.should eq 0
    list.value.should eq "z"
  end
end
