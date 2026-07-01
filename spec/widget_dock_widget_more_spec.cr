require "./spec_helper"

include Crysterm

private def dock_win
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

# Complements the existing DockWidget specs (content/close/float/grip): the
# non-floatable no-op, content replacement, and the per-area floor border.
describe Crysterm::Widget::DockWidget do
  it "ignores toggle_floating on a non-floatable dock" do
    s = dock_win
    dock = Crysterm::Widget::DockWidget.new parent: s, title: "X",
      area: Crysterm::Widget::DockWidget::Area::Left, floatable: false
    floats = 0
    dock.on(Crysterm::Event::Float) { floats += 1 }
    dock.toggle_floating
    dock.floating?.should be_false # stayed docked
    floats.should eq 0             # no Float event emitted
  end

  it "replaces a previously set content widget" do
    s = dock_win
    first = Crysterm::Widget::Box.new content: "old"
    dock = Crysterm::Widget::DockWidget.new parent: s, title: "D",
      area: Crysterm::Widget::DockWidget::Area::Right
    dock.widget = first
    dock.widget.should be(first)

    second = Crysterm::Widget::Box.new content: "new"
    dock.widget = second
    dock.widget.should be(second)
    dock.children.includes?(first).should be_false
    dock.children.includes?(second).should be_true
  end

  it "gives a floating dock a full frame and a docked one only its content-facing border" do
    s = dock_win
    floating = Crysterm::Widget::DockWidget.new parent: s, title: "F",
      area: Crysterm::Widget::DockWidget::Area::Floating
    floating.floor_border_value.should eq true # full frame

    left = Crysterm::Widget::DockWidget.new parent: s, title: "L",
      area: Crysterm::Widget::DockWidget::Area::Left
    b = left.floor_border_value
    b.should be_a Crysterm::Border
    b = b.as(Crysterm::Border)
    # Left-docked: content sits to the right, so only the right side is bordered.
    {b.left, b.top, b.right, b.bottom}.should eq({0, 0, 1, 0})

    bottom = Crysterm::Widget::DockWidget.new parent: s, title: "B",
      area: Crysterm::Widget::DockWidget::Area::Bottom
    bb = bottom.floor_border_value.as(Crysterm::Border)
    {bb.left, bb.top, bb.right, bb.bottom}.should eq({0, 1, 0, 0})
  end
end
