require "./spec_helper"

include Crysterm

# `ItemView#set_items` reuses existing item widgets in place (`set_content`) and
# relies on `#current_index=` to refresh the cached selection `#value`. But `current_index=`
# early-returns on an unchanged index, so replacing rows while the selected
# index stays the same left `@value` pointing at pre-replacement text — stale
# for `Form` value collection and other consumers. (Distinct from the
# `#set_item` and empty-list latch fixes.)
describe "ItemView#set_items selected value sync" do
  it "refreshes #value when rows are replaced and the index is unchanged" do
    s = headless_screen(80, 24)
    list = Crysterm::Widget::List.new parent: s, items: ["a", "b", "c"]
    list.current_index = 0
    list.current_text.should eq "a"

    list.items = ["X", "Y", "Z"]
    list.current_index.should eq 0
    list.current_text.should eq "X"
  end

  it "refreshes #value when the selection re-lands on the same non-zero index" do
    s = headless_screen(80, 24)
    list = Crysterm::Widget::List.new parent: s, items: ["a", "b", "c"]
    list.current_index = 1
    list.current_text.should eq "b"

    # "b" is gone, but same length, so cursor re-lands on index 1.
    list.items = ["p", "q", "r"]
    list.current_index.should eq 1
    list.current_text.should eq "q"
  end

  it "strips tags from the refreshed value, like #current_index=" do
    s = headless_screen(80, 24)
    list = Crysterm::Widget::List.new parent: s, items: ["a", "b"], parse_tags: true
    list.current_index = 0
    list.items = ["{bold}hi{/bold}", "z"]
    list.current_text.should eq "hi"
  end
end
