require "./spec_helper"

include Crysterm

private def headless_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
end

# `render_style_for` is the polymorphic hook a parent uses to dictate a child's
# render style; the base just returns the child's own style, container widgets
# (List, ...) override it to highlight the selected row (see todoc Q10). This
# replaced the `_is_list`/`is_a?` type-check that used to sit in `#_render`.
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
    # A *visibly styled* selection (a real selection color) resolves verbatim —
    # no reverse-video fallback is synthesized (see the floor case below).
    list.styles.selected = Style.new bg: "red"
    list.selected = 1

    list.render_style_for(list.items[1]).should be(list.styles.selected)
    list.render_style_for(list.items[0]).should be(list.style.item)
  end

  it "falls back to reverse-video for the selected row when no selection color is set" do
    # The unstyled floor: no theme/author CSS gives the selection a color, so the
    # cursor row must still be visible — via reverse-video, the one highlight that
    # needs no color and reads on any terminal background.
    s = headless_screen
    list = Widget::List.new parent: s, items: ["a", "b", "c"]
    list.selected = 1

    selected = list.render_style_for(list.items[1])
    selected.reverse?.should be_true
    # A fresh style, not the shared `styles.selected`/`normal` (which must stay
    # un-mutated so non-selected rows render normally).
    selected.should_not be(list.styles.selected)
    list.render_style_for(list.items[0]).reverse?.should be_false
  end
end
