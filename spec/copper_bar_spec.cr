require "./spec_helper"

include Crysterm

# `Widget::Effect::CopperBar` hue-cycling logic, driven headlessly over in-memory
# IOs so no real terminal is touched. `#step` is pure (it only repaints
# `style.bg`; it does not render or sleep), so it can be exercised directly
# without the animation fiber.

private def copper_screen
  Crysterm::Screen.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new)
end

describe Crysterm::Widget::Effect::CopperBar do
  it "paints style.bg from the hue formula and advances each step" do
    s = copper_screen
    bar = Crysterm::Widget::Effect::CopperBar.new parent: s, top: 0, left: 0,
      width: 10, height: 1, hue_offset: 0, hue_speed: 9

    bar.step
    bar.style.bg.should eq Crysterm::Colors.hsv(0) # frame 0
    bar.step
    bar.style.bg.should eq Crysterm::Colors.hsv(9) # frame 1
    bar.step
    bar.style.bg.should eq Crysterm::Colors.hsv(18) # frame 2
  end

  it "staggers bars by hue_offset" do
    s = copper_screen
    a = Crysterm::Widget::Effect::CopperBar.new parent: s, width: 10, height: 1,
      hue_offset: 0, hue_speed: 9
    b = Crysterm::Widget::Effect::CopperBar.new parent: s, width: 10, height: 1,
      hue_offset: 26, hue_speed: 9

    a.step
    b.step
    a.style.bg.should eq Crysterm::Colors.hsv(0)
    b.style.bg.should eq Crysterm::Colors.hsv(26)
  end

  it "wraps the hue around the color wheel" do
    s = copper_screen
    bar = Crysterm::Widget::Effect::CopperBar.new parent: s, width: 10, height: 1,
      hue_offset: 350, hue_speed: 20
    bar.step # 350
    bar.step # 370 -> 10
    bar.style.bg.should eq Crysterm::Colors.hsv(10)
  end

  it "honors saturation and brightness" do
    s = copper_screen
    bar = Crysterm::Widget::Effect::CopperBar.new parent: s, width: 10, height: 1,
      hue_offset: 120, hue_speed: 0, saturation: 0.5, brightness: 0.25
    bar.step
    bar.style.bg.should eq Crysterm::Colors.hsv(120, 0.5, 0.25)
  end
end
