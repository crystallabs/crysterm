require "./spec_helper"

include Crysterm

private def headless_screen(width = 80, height = 24)
  Crysterm::Screen.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: width, height: height)
end

# Re-parenting: appending a widget that already has a parent must detach it from
# the old parent before linking it to the new one, so a widget is never a child
# of two containers at once (`Widget#insert`, src/widget_children.cr). Migrated
# from `small-tests/parents.cr`, which only `STDERR.puts`ed the result.
describe "Widget re-parenting" do
  it "moves a child from its current parent to the new one" do
    s = headless_screen
    child = Widget::Box.new width: 10, height: 3, content: "child"
    a = Widget::Box.new parent: s, width: "100%", height: "100%"
    b = Widget::Box.new parent: s, width: "100%", height: "100%"

    a.append child
    child.parent.should eq a
    a.children.should eq [child]

    b.append child
    child.parent.should eq b      # now under b
    b.children.should eq [child]
    a.children.should be_empty    # and gone from a
  end

  it "emits Reparent on the child, with a nil detach between the two parents" do
    s = headless_screen
    child = Widget::Box.new width: 10, height: 3
    a = Widget::Box.new parent: s, width: "100%", height: "100%"
    b = Widget::Box.new parent: s, width: "100%", height: "100%"

    seen = [] of Widget?
    child.on(Event::Reparent) { |e| seen << e.widget }

    a.append child # adopt by a
    b.append child # detach from a (nil), then adopt by b

    seen.should eq [a, nil, b]
  end

  it "does not duplicate a child appended to the same parent twice" do
    s = headless_screen
    a = Widget::Box.new parent: s, width: "100%", height: "100%"
    child = Widget::Box.new width: 10, height: 3

    a.append child
    a.append child

    a.children.should eq [child]
  end
end
