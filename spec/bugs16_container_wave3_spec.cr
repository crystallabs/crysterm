require "./spec_helper"

include Crysterm

# `DockWidget#floating=` performs the full float bookkeeping (geometry
# pinning, `Event::TopLevelChanged`), keeps `#area` as the home to return to,
# and is not gated on `floatable?` (which gates the gesture, not the API);
# assigning `#area=` to a floating dock re-docks it there.
describe "BUGS16 B16-45: DockWidget floating transitions" do
  it "pins geometry, keeps the home area, and emits TopLevelChanged" do
    s = headless_screen(80, 24)
    win = Widget::MainWindow.new parent: s, top: 0, left: 0, width: 80, height: 24
    dock = Widget::DockWidget.new title: "D", area: Widget::DockWidget::Area::Right
    win.add_dock dock
    s.repaint

    states = [] of Bool
    dock.on(Crysterm::Event::TopLevelChanged) { |e| states << e.floating }

    dock.floating = true
    dock.floating?.should be_true
    # No docked constraints; explicit rect pinned.
    dock.right.nil?.should be_true
    dock.bottom.nil?.should be_true
    dock.left.nil?.should be_false
    dock.top.nil?.should be_false
    dock.area.should eq Widget::DockWidget::Area::Right # home area retained
    states.should eq [true]
  ensure
    s.try &.destroy
  end

  it "still works programmatically on a floatable: false dock" do
    s = headless_screen(80, 24)
    win = Widget::MainWindow.new parent: s, top: 0, left: 0, width: 80, height: 24
    dock = Widget::DockWidget.new title: "D",
      area: Widget::DockWidget::Area::Left, floatable: false
    win.add_dock dock
    s.repaint

    dock.floating = true
    dock.floating?.should be_true # floatable gates the gesture, not the API
  ensure
    s.try &.destroy
  end

  it "saves the float geometry on a programmatic re-dock via area=" do
    s = headless_screen(80, 24)
    win = Widget::MainWindow.new parent: s, top: 0, left: 0, width: 80, height: 24
    dock = Widget::DockWidget.new title: "D", area: Widget::DockWidget::Area::Right
    win.add_dock dock
    s.repaint

    dock.floating = true
    s.repaint
    dock.area = Widget::DockWidget::Area::Bottom
    dock.@float_geom.nil?.should be_false # remembered for the next float
    dock.floating?.should be_false
    dock.area.should eq Widget::DockWidget::Area::Bottom
  ensure
    s.try &.destroy
  end
end

# B16-46 — `tab_position=`/`tab_height=` were plain properties: the bar stayed
# where the constructor put it, existing pages kept their baked-in insets, and
# only later-added tabs used the new value — the widget ended up half in each
# layout.
describe "BUGS16 B16-46: TabWidget tab_position/tab_height runtime changes" do
  it "moves the bar and re-insets existing pages on tab_position=" do
    s = headless_screen(80, 24)
    tw = Widget::TabWidget.new parent: s, top: 0, left: 0, width: 30, height: 8
    pa = Widget::Box.new content: "A"
    tw.add_tab "A", pa
    s.repaint

    tw.tab_bar.top.should eq 0
    pa.top.should eq 1

    tw.tab_position = Widget::TabWidget::Position::Bottom
    tw.tab_bar.top.should be_nil # opposite anchor cleared — not over-constrained
    tw.tab_bar.bottom.should eq 0
    pa.top.should eq 0
    pa.bottom.should eq 1

    # A tab added after the change lands in the same layout.
    pb = Widget::Box.new content: "B"
    tw.add_tab "B", pb
    pb.top.should eq 0
    pb.bottom.should eq 1
  ensure
    s.try &.destroy
  end

  it "re-insets pages on tab_height=" do
    s = headless_screen(80, 24)
    tw = Widget::TabWidget.new parent: s, top: 0, left: 0, width: 30, height: 8
    pa = Widget::Box.new content: "A"
    tw.add_tab "A", pa
    s.repaint

    tw.tab_height = 2
    tw.tab_bar.height_spec.should eq 2
    pa.top.should eq 2
  ensure
    s.try &.destroy
  end
end
