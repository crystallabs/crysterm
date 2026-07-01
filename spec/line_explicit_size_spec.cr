require "./spec_helper"

include Crysterm

# `Widget::Line` (and its `HLine`/`VLine` aliases) take a convenience `size`
# argument that sets the line's length (`width` when horizontal, `height` when
# vertical). It used to default to `"100%"` and apply unconditionally,
# silently overwriting an explicit `width:`/`height:` passed through `**box`:
# `HLine.new(width: 40)` rendered full-width regardless. An explicit dimension
# must now win; only a line given no length falls back to filling its parent.

private def line_mem_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

describe Crysterm::Widget::Line do
  it "honors an explicit width on a horizontal line" do
    s = line_mem_screen
    h = Crysterm::Widget::HLine.new parent: s, top: 0, left: 4, width: 40
    h.width.should eq 40
  end

  it "honors an explicit height on a vertical line" do
    s = line_mem_screen
    v = Crysterm::Widget::VLine.new parent: s, top: 2, left: 0, height: 16
    v.height.should eq 16
  end

  it "still fills its parent when given no explicit length" do
    s = line_mem_screen
    h = Crysterm::Widget::HLine.new parent: s, top: 0, left: 0
    h.width.should eq "100%"
  end

  it "still honors the explicit size convenience argument" do
    s = line_mem_screen
    h = Crysterm::Widget::HLine.new parent: s, top: 0, left: 0, size: 30
    h.width.should eq 30
  end
end
