require "./spec_helper"

include Crysterm

# `ItemView#set_item` must keep the cached selection `#value` in sync when it
# rewrites the *selected* row's text. `@value` is otherwise only refreshed by
# `#current_index=`, which early-returns on an unchanged index, so in-place edits left
# `value` pointing at stale text (real path: `Pine` re-formats its selected
# status row via `set_item selected, ...`; `ListTable` re-sets content during
# layout). Tags are stripped, matching `#current_index=`.
describe "ItemView#set_item selected value sync" do
  it "updates #value when the selected row's content changes" do
    s = headless_screen(80, 24)
    list = Crysterm::Widget::List.new parent: s, items: ["a", "b", "c"]
    list.current_index = 1 # "b"
    list.current_text.should eq "b"

    list.set_item 1, "B!"
    list.current_text.should eq "B!"
  end

  it "strips tags from the refreshed value, like #current_index=" do
    s = headless_screen(80, 24)
    list = Crysterm::Widget::List.new parent: s, items: ["a", "b"], parse_tags: true
    list.current_index = 0
    list.set_item 0, "{bold}hi{/bold}"
    list.current_text.should eq "hi"
  end

  it "leaves #value untouched when a non-selected row changes" do
    s = headless_screen(80, 24)
    list = Crysterm::Widget::List.new parent: s, items: ["a", "b", "c"]
    list.current_index = 0 # "a"
    list.set_item 2, "C!"
    list.current_text.should eq "a"
  end
end
