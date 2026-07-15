require "./spec_helper"

include Crysterm

private def headless_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
end

# `render_style_for` is the polymorphic hook a parent uses to dictate a child's
# render style; the base returns the child's own style, container widgets
# (List, ...) override it to highlight the selected row (see todoc Q10). This
# replaced the `_is_list`/`is_a?` type-check formerly in `#_render`.
describe "Widget#render_style_for" do
  it "returns the child's own style by default" do
    s = headless_screen
    parent = Widget::Box.new parent: s
    child = Widget::Box.new parent: parent

    parent.render_style_for(child).should be(child.style)
  end

  it "resolves the selected row to the selected style in a List" do
    s = headless_screen
    list = Widget::List.new parent: s, items: ["a", "b", "c"]
    list.style.item = Style.new
    # A visibly-styled selection (real selection color) resolves verbatim — no
    # reverse-video fallback is synthesized (see the floor case below).
    list.styles.selected = Style.new bg: "red"
    list.selected = 1

    list.render_style_for(list.items[1]).should be(list.styles.selected)
    list.render_style_for(list.items[0]).should be(list.style.item)
  end

  it "falls back to reverse-video for the selected row when no selection color is set" do
    # Unstyled floor: no theme/author CSS colors the selection, so the cursor row
    # must still be visible via reverse-video — the one highlight needing no
    # color that reads on any terminal background.
    s = headless_screen
    list = Widget::List.new parent: s, items: ["a", "b", "c"]
    list.selected = 1

    selected = list.render_style_for(list.items[1])
    selected.reverse?.should be_true
    # A fresh style, not the shared `styles.selected`/`normal` (must stay
    # unmutated so non-selected rows render normally).
    selected.should_not be(list.styles.selected)
    list.render_style_for(list.items[0]).reverse?.should be_false
  end
end

# The multi-select render path (`render_style_for`/`item_selected?`) resolves an
# item widget to its index via a lazily-built identity map (`@item_index`),
# invalidated on every `@items` mutation. These lock in that the map returns each
# item's *current* index after add/remove/insert reorders — a stale map would
# report a pre-mutation index and mis-highlight rows.
describe "Mixin::ItemView multi-select index map" do
  it "tracks the same item widget's index after appending" do
    s = headless_screen
    list = Widget::List.new parent: s, selection_mode: :multi_selection, items: ["a", "b", "c"]
    b = list.items[1]
    list.add_to_selection 1

    list.item_selected?(b).should be_true
    list.add_item "d"
    # `b` is still at index 1, and index 1 is still marked.
    list.item_selected?(b).should be_true
    list.item_selected?(list.items[3]).should be_false
  end

  it "resolves an item's shifted index after inserting before it" do
    s = headless_screen
    list = Widget::List.new parent: s, selection_mode: :multi_selection, items: ["a", "b", "c"]
    b = list.items[1]
    list.add_to_selection 1 # marks index 1 (b)

    # Inserting at the front slides every item down one: b moves to index 2 and
    # `@selected_indices` slides {1} -> {2}. `item_selected?(b)` is only true if
    # the rebuilt map reports b's new index (2), not the stale 1.
    list.insert_item 0, "z"
    list.items[2].should be(b)
    list.item_selected?(b).should be_true
    # Only b is in the multi-selection — `selected_values` reflects the set
    # alone (cursor-independent, unlike `item_selected?` which also honors the
    # single-select cursor `@selected`).
    list.selected_values.should eq ["b"]
  end

  it "resolves an item's shifted index after removing before it" do
    s = headless_screen
    list = Widget::List.new parent: s, selection_mode: :multi_selection, items: ["a", "b", "c", "d"]
    c = list.items[2]
    list.add_to_selection 2 # marks index 2 (c)

    # Removing the first item slides c up to index 1; `@selected_indices` slides
    # {2} -> {1}. Correct only if the map reports c's new index.
    list.remove_item list.items[0]
    list.items[1].should be(c)
    list.item_selected?(c).should be_true
    # Only c remains in the multi-selection (cursor-independent check).
    list.selected_values.should eq ["c"]
  end
end
