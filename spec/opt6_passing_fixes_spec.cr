require "./spec_helper"

include Crysterm

# Regression specs for a bundle of small "bugs noticed in passing" items:
#
#  1. `StackedWidget` never emitted `Event::ItemRemoved` on `#remove_widget`/
#     `#remove`, unlike its `TabWidget`/`ToolBox` siblings.
#  2. None of the three paged containers (`StackedWidget`, `TabWidget`,
#     `ToolBox`) emitted `Event::ItemAdded` on their add path, unlike
#     `Mixin::ItemView`/`Mixin::ActionBar`.
#  3. `Media::Regis#to_logical_x`/`#to_logical_y` called the raising `window`
#     accessor, so a detached widget's public `#target_pixels` raised instead
#     of falling back like every sibling backend.
#  4. `Layout::UniformGrid` positions must stay unchanged after documenting
#     the (intentionally left alone) O4-16 double-`awidth`-resolution note.

describe "StackedWidget ItemAdded/ItemRemoved" do
  it "emits ItemAdded from #add_widget" do
    s = headless_screen(80, 24)
    sw = Widget::StackedWidget.new parent: s, width: 20, height: 6
    added = 0
    sw.on(::Crysterm::Event::ItemAdded) { added += 1 }

    sw.add_widget Widget::Box.new(content: "page 1")
    added.should eq 1

    sw.add_widget Widget::Box.new(content: "page 2")
    added.should eq 2
  ensure
    s.try &.destroy
  end

  it "emits ItemRemoved from #remove_widget" do
    s = headless_screen(80, 24)
    sw = Widget::StackedWidget.new parent: s, width: 20, height: 6
    p1 = Widget::Box.new(content: "page 1")
    sw.add_widget p1
    sw.add_widget Widget::Box.new(content: "page 2")

    removed = 0
    sw.on(::Crysterm::Event::ItemRemoved) { removed += 1 }

    sw.remove_widget(p1)
    removed.should eq 1
  ensure
    s.try &.destroy
  end

  it "emits ItemRemoved from a bare #remove (direct detach path)" do
    s = headless_screen(80, 24)
    sw = Widget::StackedWidget.new parent: s, width: 20, height: 6
    p1 = Widget::Box.new(content: "page 1")
    sw.add_widget p1
    sw.add_widget Widget::Box.new(content: "page 2")

    removed = 0
    sw.on(::Crysterm::Event::ItemRemoved) { removed += 1 }

    # A direct `#remove` (not `#remove_widget`) must go through the same
    # `Event::ItemRemoved` announcement — the path `page.destroy`/
    # `#detach_from_tree` land on.
    sw.remove(p1)
    removed.should eq 1
  ensure
    s.try &.destroy
  end
end

describe "Paged containers emit ItemAdded on add" do
  it "TabWidget#add_tab emits ItemAdded" do
    s = headless_screen(80, 24)
    tw = Widget::TabWidget.new parent: s, width: 40, height: 12
    added = 0
    tw.on(::Crysterm::Event::ItemAdded) { added += 1 }

    tw.add_tab "Files", Widget::Box.new(content: "...")
    added.should eq 1

    tw.add_tab "Edit", Widget::Box.new(content: "...")
    added.should eq 2
  ensure
    s.try &.destroy
  end

  it "ToolBox#add_item emits ItemAdded" do
    s = headless_screen(80, 24)
    tb = Widget::ToolBox.new parent: s, width: 30, height: 16
    added = 0
    tb.on(::Crysterm::Event::ItemAdded) { added += 1 }

    tb.add_item "General", Widget::Box.new(content: "...")
    added.should eq 1

    tb.add_item "Advanced", Widget::Box.new(content: "...")
    added.should eq 2
  ensure
    s.try &.destroy
  end
end

describe "Media::Regis detached #target_pixels" do
  it "does not raise off the raising `window` accessor when detached" do
    # A parentless construction falls back to the global window
    # (`Widget#determine_window`), so build attached and then detach — the
    # same pattern `bugs13_wtop_cursor_spec.cr`'s `detached_box` uses.
    s = headless_screen(80, 24)
    img = Widget::Media::Regis.new parent: s, width: 10, height: 5
    s.remove img
    img.window?.should be_nil

    px = img.target_pixels(10, 5)
    px.should be_a Tuple(Int32, Int32)
    # Falls back to the same 80x24 default the constructor uses (regis.cr:76-79).
    px[0].should be > 0
    px[1].should be > 0
  ensure
    s.try &.destroy
  end
end

describe "UniformGrid layout positions" do
  it "positions children at a uniform column pitch unchanged by the O4-16 note" do
    s = headless_screen(80, 24)
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 30, height: 10,
      layout: Layout::UniformGrid.new
    a = Widget::Box.new parent: box, width: 6, height: 2
    b = Widget::Box.new parent: box, width: 10, height: 2
    c = Widget::Box.new parent: box, width: 6, height: 2

    s.repaint

    bl = box.lpos.not_nil!
    al = a.lpos.not_nil!
    bpl = b.lpos.not_nil!
    cl = c.lpos.not_nil!

    # Every child snaps to the widest child's width (10).
    al.xi.should eq bl.xi
    bpl.xi.should eq bl.xi + 10
    cl.xi.should eq bl.xi + 20
    al.yi.should eq bl.yi
    bpl.yi.should eq bl.yi
    cl.yi.should eq bl.yi
  ensure
    s.try &.destroy
  end
end
