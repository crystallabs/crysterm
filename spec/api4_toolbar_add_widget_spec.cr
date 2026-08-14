require "./spec_helper"

# API4 A4-38b: `ToolBar#add_widget` — an arbitrary widget embedded in the action
# strip (Qt's `QToolBar::addWidget`), laid out by the `Mixin::ActionBar` item
# model alongside the buttons/separators.
#
# NOTE the bars pack their item boxes in `#paint`, so every position assertion
# here is made after an explicit `Window#repaint` — nothing lays the strip out
# on its own in a headless window.
describe "API4 A4-38b: ToolBar#add_widget" do
  it "hosts the widget as a strip item flowing between the surrounding actions" do
    s = headless_screen 80, 24
    tb = Crysterm::Widget::ToolBar.new parent: s, top: 0, left: 0, width: 40, height: 1
    tb.add_button("New") { }
    field = Crysterm::Widget::Box.new parent: s, width: 10, height: 1, content: "search"
    ret = tb.add_widget field
    tb.add_button("Quit") { }
    s.repaint

    # The widget itself is the handle handed back (see `#remove_widget`).
    ret.should be field

    # It counts as one item, in insertion order, with its own host box.
    tb.count.should eq 3
    tb.item_boxes.size.should eq 3
    host = tb.item_boxes[1]
    field.parent.should be host

    # `item_gap` is 0 on a tool bar, so items pack flush: "New" is
    # `str_width + 2` = 5 cells, the embedded slot the widget's own 10, and
    # "Quit" follows at 15.
    tb.item_boxes[0].left.should eq 0
    host.left.should eq 5
    host.awidth.should eq 10
    tb.item_boxes[2].left.should eq 15

    # The widget is painted where the strip put its host, not where it was
    # before being embedded.
    field.aleft.should eq host.aleft
    field.atop.should eq host.atop
  end

  it "reserves an explicit width when asked, overriding the widget's own" do
    s = headless_screen 80, 24
    tb = Crysterm::Widget::ToolBar.new parent: s, top: 0, left: 0, width: 40, height: 1
    tb.add_button("New") { }
    # A stretched (nil-width) widget has no fixed size of its own: the caller
    # states how many cells the strip should reserve, and the widget fills them.
    field = Crysterm::Widget::Box.new parent: s, height: 1, content: "search"
    tb.add_widget field, width: 12
    tb.add_button("Quit") { }
    s.repaint

    tb.item_boxes[1].awidth.should eq 12
    tb.item_boxes[2].left.should eq 5 + 12
    field.awidth.should eq 12
  end

  it "re-packs the strip when the embedded item is removed, and hands the widget back free" do
    s = headless_screen 80, 24
    tb = Crysterm::Widget::ToolBar.new parent: s, top: 0, left: 0, width: 40, height: 1
    tb.add_button("New") { }
    field = Crysterm::Widget::Box.new parent: s, width: 10, height: 1, content: "search"
    tb.add_widget field
    tb.add_button("Quit") { }
    s.repaint
    tb.item_boxes[2].left.should eq 15

    tb.remove_widget(field).should be field
    s.repaint

    tb.count.should eq 2
    tb.item_boxes.size.should eq 2
    # "Quit" closed the 10-cell gap the embedded item held.
    tb.item_boxes[1].left.should eq 5
    # The widget survives detached (not destroyed), ready to be re-used.
    field.parent.should be_nil
    tb.item_boxes.should_not contain field

    # Removing a widget that isn't on the bar is a no-op.
    tb.remove_widget(field).should be_nil
    tb.count.should eq 2
  end

  it "skips embedded items in keyboard cycling and selection" do
    s = headless_screen 80, 24
    tb = Crysterm::Widget::ToolBar.new parent: s, top: 0, left: 0, width: 40, height: 1
    fired = 0
    tb.add_button("New") { fired += 1 }
    field = Crysterm::Widget::Box.new parent: s, width: 10, height: 1, content: "search"
    tb.add_widget field
    tb.add_button("Quit") { fired += 1 }
    s.repaint

    # The first *selectable* item is auto-selected; the embedded one never is.
    tb.current_index.should eq 0

    # Right/left step over the embedded item, exactly as over a separator.
    tb.move_right
    tb.current_index.should eq 2
    tb.move_left
    tb.current_index.should eq 0

    # Selecting/activating it directly is a no-op — no highlight, no callback.
    tb.select_item 1
    tb.current_index.should eq 0
    tb.activate_item 1
    fired.should eq 0
  end

  it "renders a bar carrying an embedded widget without raising" do
    s = headless_screen 80, 24
    tb = Crysterm::Widget::ToolBar.new parent: s, top: 0, left: 0, width: 40, height: 1
    tb.add_button("New") { }
    tb.add_separator
    field = Crysterm::Widget::Box.new parent: s, width: 8, height: 1, content: "srch"
    tb.add_widget field
    s.repaint

    # The widget's own content lands on the strip row.
    row = s.lines[tb.atop].map(&.char).join
    row.should contain "srch"

    # And keeps rendering after the strip changes around it.
    tb.add_button("Quit") { }
    s.repaint
    s.lines[tb.atop].map(&.char).join.should contain "srch"
  end
end
