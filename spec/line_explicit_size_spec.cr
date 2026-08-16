require "./spec_helper"

include Crysterm

# `Widget::Line` (and its `HLine`/`VLine` aliases) take a convenience `line_size`
# argument that sets the line's length (`width` when horizontal, `height` when
# vertical). An explicit `width:`/`height:` passed through `**box` must win over
# the `"100%"` default (`HLine.new(width: 40)` renders 40 wide, not full-width);
# only a line given no length falls back to filling its parent.

describe Crysterm::Widget::Line do
  it "honors an explicit width on a horizontal line" do
    s = headless_screen(80, 24)
    h = Crysterm::Widget::HLine.new parent: s, top: 0, left: 4, width: 40
    h.width_spec.should eq 40
  end

  it "honors an explicit height on a vertical line" do
    s = headless_screen(80, 24)
    v = Crysterm::Widget::VLine.new parent: s, top: 2, left: 0, height: 16
    v.height_spec.should eq 16
  end

  it "still fills its parent when given no explicit length" do
    s = headless_screen(80, 24)
    h = Crysterm::Widget::HLine.new parent: s, top: 0, left: 0
    h.width_spec.as(Crysterm::Dim).matches?("100%").should be_true
  end

  it "still honors the explicit size convenience argument" do
    s = headless_screen(80, 24)
    h = Crysterm::Widget::HLine.new parent: s, top: 0, left: 0, line_size: 30
    h.width_spec.should eq 30
  end
end
