require "./spec_helper"

include Crysterm

private def sisv_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

# `ItemView#set_item` must keep the cached selection `#value` in sync when it
# rewrites the *selected* row's text. `@value` is otherwise only refreshed by
# `#selekt`, which early-returns on an unchanged index, so in-place edits left
# `value` pointing at stale text (real path: `Pine` re-formats its selected
# status row via `set_item selected, ...`; `ListTable` re-sets content during
# layout). Tags are stripped, matching `#selekt`.
describe "ItemView#set_item selected value sync" do
  it "updates #value when the selected row's content changes" do
    s = sisv_screen
    list = Crysterm::Widget::List.new parent: s, items: ["a", "b", "c"]
    list.selekt 1 # "b"
    list.value.should eq "b"

    list.set_item 1, "B!"
    list.value.should eq "B!"
  end

  it "strips tags from the refreshed value, like #selekt" do
    s = sisv_screen
    list = Crysterm::Widget::List.new parent: s, items: ["a", "b"], parse_tags: true
    list.selekt 0
    list.set_item 0, "{bold}hi{/bold}"
    list.value.should eq "hi"
  end

  it "leaves #value untouched when a non-selected row changes" do
    s = sisv_screen
    list = Crysterm::Widget::List.new parent: s, items: ["a", "b", "c"]
    list.selekt 0 # "a"
    list.set_item 2, "C!"
    list.value.should eq "a"
  end
end
