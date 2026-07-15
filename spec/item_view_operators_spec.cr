require "./spec_helper"

include Crysterm

private def ivo_window
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

# `Mixin::ItemView`/`Mixin::ActionBar` alias `#<<` to `#add_item` and `#>>` to
# `#remove_item` via `alias_previous`, which expands to an *unrestricted*
# `def <<(*args)`. Every `Widget` separately includes `Mixin::Children`, whose
# `#<<(Widget)` appends a child widget — and the mixin sits ahead of `Widget` in
# the ancestor chain.
#
# So these specs exist to pin down the overload split: the typed `#<<(Widget)`
# must stay the more specific match for a `Widget` argument, or every existing
# `view << some_widget` call site would silently flip from child-append to
# item-append. That is a behavior change no compiler error would catch.
describe "Mixin::ItemView operator aliases" do
  it "appends an item via #<< with a String" do
    s = ivo_window
    list = Crysterm::Widget::List.new parent: s, width: 20, height: 10
    list << "one"
    list << "two"
    list.count.should eq 2
    list.item(0).try(&.rendered_content).should eq "one"
    list.item(1).try(&.rendered_content).should eq "two"
  end

  it "removes an item via #>> with its text" do
    s = ivo_window
    list = Crysterm::Widget::List.new parent: s, width: 20, height: 10
    list << "one"
    list << "two"
    list >> "one"
    list.count.should eq 1
    list.item(0).try(&.rendered_content).should eq "two"
  end

  # The load-bearing one: `<<` with a Widget must NOT become add_item.
  it "still appends a *child widget* via #<<(Widget), not an item" do
    s = ivo_window
    list = Crysterm::Widget::List.new parent: s, width: 20, height: 10
    before = list.count
    box = Crysterm::Widget::Box.new width: 5, height: 1, content: "child"
    list << box
    list.count.should eq before      # no item was added
    list.children.should contain box # it became a child
    box.parent.should eq list
  end
end

describe "Mixin::ActionBar operator aliases" do
  it "appends a command via #<< with a String" do
    s = ivo_window
    bar = Crysterm::Widget::ListBar.new parent: s, width: 40, height: 1
    bar << "one"
    bar << "two"
    bar.count.should eq 2
  end

  it "removes a command via #>> with its index" do
    s = ivo_window
    bar = Crysterm::Widget::ListBar.new parent: s, width: 40, height: 1
    bar << "one"
    bar << "two"
    bar >> 0
    bar.count.should eq 1
  end

  it "still appends a *child widget* via #<<(Widget), not a command" do
    s = ivo_window
    bar = Crysterm::Widget::ListBar.new parent: s, width: 40, height: 1
    before = bar.count
    box = Crysterm::Widget::Box.new width: 5, height: 1, content: "child"
    bar << box
    bar.count.should eq before
    bar.children.should contain box
    box.parent.should eq bar
  end
end

describe "Widget::Menu operator aliases" do
  it "adds via #<< and removes via #>>, mirroring #remove_action" do
    s = ivo_window
    menu = Crysterm::Widget::Menu.new parent: s
    a = Action.new "Bold"
    menu << a
    menu.count.should eq 1
    menu >> a
    menu.count.should eq 0
    a.associated_widgets.empty?.should be_true
  end
end
