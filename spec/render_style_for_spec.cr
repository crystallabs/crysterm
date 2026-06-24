require "./spec_helper"

include Crysterm

private def headless_screen
  Crysterm::Screen.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
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
    list.styles.selected = Style.new
    list.selected = 1

    list.render_style_for(list.items[1]).should be(list.styles.selected)
    list.render_style_for(list.items[0]).should be(list.style.item)
  end
end
