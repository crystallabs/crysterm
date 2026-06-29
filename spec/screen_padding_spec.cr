require "./spec_helper"

include Crysterm

private def headless_screen(width = 80, height = 24, padding = nil)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: width, height: height, padding: padding)
end

# Window-level padding (`Window.new padding: N`). A `Window` carries a `Padding`
# for widget compatibility, and as a side effect the whole screen can be inset:
# a child placed at (0,0) lands *after* the padding, and `width: "100%"` fills
# only the padded content area (see `src/screen_decoration.cr`). This is distinct
# from per-widget/Box padding (covered by `tests/blessed-test/widget-padding.cr`)
# and is demonstrated nowhere else. Migrated from `small-tests/screen-padding.cr`.
describe "Window-level padding" do
  it "defaults to no padding" do
    s = headless_screen
    s.padding.any?.should be_false
    s.iwidth.should eq 0
    s.iheight.should eq 0
  end

  it "applies a uniform Int padding to all four sides" do
    s = headless_screen padding: 4

    s.ileft.should eq 4
    s.itop.should eq 4
    s.iright.should eq 4
    s.ibottom.should eq 4
    s.iwidth.should eq 8  # left + right
    s.iheight.should eq 8 # top + bottom
  end

  it "offsets a child at (0,0) by the padding" do
    s = headless_screen padding: 4
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 5

    box.aleft.should eq 4
    box.atop.should eq 4
  end

  it "shrinks a width/height: 100% child to the padded content area" do
    s = headless_screen width: 80, height: 24, padding: 4
    box = Widget::Box.new parent: s, top: 0, left: 0, width: "100%", height: "100%"

    box.awidth.should eq 80 - s.iwidth   # 72
    box.aheight.should eq 24 - s.iheight # 16
  end
end
