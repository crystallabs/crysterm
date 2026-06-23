require "./spec_helper"

include Crysterm

private def headless_screen
  Crysterm::Screen.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
end

# `center±N` (positions) and `half±N` (sizes) used to crash (`Invalid Float64`)
# because the offset form bypassed the alias->"50%" mapping. These assert the
# offset is applied relative to the plain centered/half value.
describe "center±N / half±N position & size offsets" do
  it "offsets a centered top/left by the trailing amount" do
    s = headless_screen
    base = Widget::Box.new parent: s, top: "center", left: "center", width: 14, height: 4
    plus = Widget::Box.new parent: s, top: "center+5", left: "center+2", width: 14, height: 4
    minus = Widget::Box.new parent: s, top: "center-3", left: "center", width: 14, height: 4

    plus.atop.should eq base.atop + 5
    plus.aleft.should eq base.aleft + 2
    minus.atop.should eq base.atop - 3
  end

  it "offsets a half size by the trailing amount" do
    s = headless_screen
    half = Widget::Box.new parent: s, width: "half", height: "half"
    plus = Widget::Box.new parent: s, width: "half+2", height: "half-1"

    plus.awidth.should eq half.awidth + 2
    plus.aheight.should eq half.aheight - 1
  end
end
