require "./spec_helper"

include Crysterm

# Regression specs for BUGS16 wave-3 container findings: B16-45, B16-46.

private def cw3_screen(w = 80, h = 24)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

# B16-45 — `DockWidget#area=` to `Floating` skipped `toggle_floating`'s
# bookkeeping: the docked anchors (`right`/`bottom`) survived and fought the
# drag handler, `@prev_area` was never recorded (a later re-dock went to
# `Left` regardless of origin), and no `Event::Float` fired.
describe "BUGS16 B16-45: DockWidget#area= Floating performs the float bookkeeping" do
  it "pins geometry, records prev_area, and emits Float" do
    s = cw3_screen
    win = Widget::MainWindow.new parent: s, top: 0, left: 0, width: 80, height: 24
    dock = Widget::DockWidget.new title: "D", area: Widget::DockWidget::Area::Right
    win.add_dock dock
    s._render
    dock.right.should_not be_nil # docked anchor from relayout

    states = [] of Bool
    dock.on(Crysterm::Event::Float) { |e| states << e.value }

    dock.area = Widget::DockWidget::Area::Floating
    dock.floating?.should be_true
    # Stale docked constraints cleared; explicit rect pinned.
    dock.right.should be_nil
    dock.bottom.should be_nil
    dock.left.should_not be_nil
    dock.top.should_not be_nil
    dock.@prev_area.should eq Widget::DockWidget::Area::Right
    states.should eq [true]
  ensure
    s.try &.destroy
  end

  it "still works programmatically on a floatable: false dock" do
    s = cw3_screen
    win = Widget::MainWindow.new parent: s, top: 0, left: 0, width: 80, height: 24
    dock = Widget::DockWidget.new title: "D",
      area: Widget::DockWidget::Area::Left, floatable: false
    win.add_dock dock
    s._render

    dock.area = Widget::DockWidget::Area::Floating
    dock.floating?.should be_true # floatable gates the gesture, not the API
  ensure
    s.try &.destroy
  end

  it "saves the float geometry on a programmatic re-dock" do
    s = cw3_screen
    win = Widget::MainWindow.new parent: s, top: 0, left: 0, width: 80, height: 24
    dock = Widget::DockWidget.new title: "D", area: Widget::DockWidget::Area::Right
    win.add_dock dock
    s._render

    dock.area = Widget::DockWidget::Area::Floating
    s._render
    dock.area = Widget::DockWidget::Area::Bottom
    dock.@float_geom.should_not be_nil # remembered for the next float
    dock.floating?.should be_false
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
    s = cw3_screen
    tw = Widget::TabWidget.new parent: s, top: 0, left: 0, width: 30, height: 8
    pa = Widget::Box.new content: "A"
    tw.add_tab "A", pa
    s._render

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
    s = cw3_screen
    tw = Widget::TabWidget.new parent: s, top: 0, left: 0, width: 30, height: 8
    pa = Widget::Box.new content: "A"
    tw.add_tab "A", pa
    s._render

    tw.tab_height = 2
    tw.tab_bar.height.should eq 2
    pa.top.should eq 2
  ensure
    s.try &.destroy
  end
end
