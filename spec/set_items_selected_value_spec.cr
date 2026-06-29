require "./spec_helper"

include Crysterm

private def sisv2_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

# `ItemView#set_items` reuses the existing item widgets in place (`set_content`)
# and relies on `#selekt` to refresh the cached selection `#value`. But `selekt`
# early-returns on an unchanged index, so when the row set is replaced while the
# selected index stays the same, `@value` was left pointing at the
# *pre-replacement* text — stale for `Form` value collection and any other
# `value` consumer. (Distinct from the `#set_item` and empty-list latch fixes.)
describe "ItemView#set_items selected value sync" do
  it "refreshes #value when rows are replaced and the index is unchanged" do
    s = sisv2_screen
    list = Crysterm::Widget::List.new parent: s, items: ["a", "b", "c"]
    list.selekt 0
    list.value.should eq "a"

    list.set_items ["X", "Y", "Z"]
    list.selected.should eq 0
    list.value.should eq "X"
  end

  it "refreshes #value when the selection re-lands on the same non-zero index" do
    s = sisv2_screen
    list = Crysterm::Widget::List.new parent: s, items: ["a", "b", "c"]
    list.selekt 1
    list.value.should eq "b"

    # "b" is gone; same length, so the cursor re-lands on index 1.
    list.set_items ["p", "q", "r"]
    list.selected.should eq 1
    list.value.should eq "q"
  end

  it "strips tags from the refreshed value, like #selekt" do
    s = sisv2_screen
    list = Crysterm::Widget::List.new parent: s, items: ["a", "b"], parse_tags: true
    list.selekt 0
    list.set_items ["{bold}hi{/bold}", "z"]
    list.value.should eq "hi"
  end
end
