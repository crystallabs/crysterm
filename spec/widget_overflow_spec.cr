require "./spec_helper"

include Crysterm

private def headless_screen(width = 80, height = 24)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: width, height: height)
end

# Per-widget `overflow` override that falls back to the screen's default when
# unset (see todoc Q2). A plain widget follows the screen-wide policy; setting
# `overflow=` overrides it per widget; setting it to `nil` re-inherits.
describe "Widget#overflow inheritance" do
  it "inherits the screen's overflow when the widget has no override" do
    s = headless_screen
    box = Widget::Box.new parent: s

    box.own_overflow.should be_nil
    box.overflow.should eq s.overflow
  end

  it "tracks the screen default when it changes" do
    s = headless_screen
    box = Widget::Box.new parent: s

    s.overflow = Crysterm::Overflow::Hidden
    box.overflow.should eq Crysterm::Overflow::Hidden
  end

  it "lets a per-widget override win over the screen default" do
    s = headless_screen
    s.overflow = Crysterm::Overflow::Hidden
    box = Widget::Box.new parent: s

    box.overflow = Crysterm::Overflow::ShrinkWidget
    box.own_overflow.should eq Crysterm::Overflow::ShrinkWidget
    box.overflow.should eq Crysterm::Overflow::ShrinkWidget
  end

  it "re-inherits when the override is cleared with nil" do
    s = headless_screen
    s.overflow = Crysterm::Overflow::Hidden
    box = Widget::Box.new parent: s, overflow: Crysterm::Overflow::ShrinkWidget

    box.overflow = nil
    box.own_overflow.should be_nil
    box.overflow.should eq Crysterm::Overflow::Hidden
  end

  it "accepts a string/symbol shorthand" do
    s = headless_screen
    box = Widget::Box.new parent: s

    box.overflow = "shrink_widget"
    box.overflow.should eq Crysterm::Overflow::ShrinkWidget
    box.overflow = :ignore
    box.overflow.should eq Crysterm::Overflow::Ignore
  end

  it "falls back to Ignore for a screen-less widget" do
    Widget::Box.new.overflow.should eq Crysterm::Overflow::Ignore
  end
end

# `Overflow::MoveWidget`: a widget that would run off the screen edge is
# translated (size preserved) to stay within the screen's visible area, rather
# than clipped. Child-policy — the widget declares it for itself (see todoc Q8).
describe "Overflow::MoveWidget" do
  it "slides a bottom/right-overflowing widget back on screen" do
    s = headless_screen
    box = Widget::Box.new parent: s,
      top: 22, left: 78, width: 6, height: 5,
      overflow: Crysterm::Overflow::MoveWidget

    s_right = s.awidth - s.iright
    s_bottom = s.aheight - s.ibottom

    coords = box._get_coords.not_nil!
    coords.xl.should eq s_right         # right edge pulled onto screen
    (coords.xl - coords.xi).should eq 6 # width preserved
    coords.yl.should eq s_bottom        # bottom edge pulled onto screen
    (coords.yl - coords.yi).should eq 5 # height preserved
  end

  it "leaves a widget that already fits untouched" do
    s = headless_screen
    box = Widget::Box.new parent: s,
      top: 2, left: 2, width: 6, height: 5,
      overflow: Crysterm::Overflow::MoveWidget

    coords = box._get_coords.not_nil!
    coords.xi.should eq 2
    coords.yi.should eq 2
  end

  it "does not move a widget that uses the default (inherited) overflow" do
    s = headless_screen
    box = Widget::Box.new parent: s, top: 22, left: 2, width: 6, height: 5

    coords = box._get_coords.not_nil!
    coords.yi.should eq 22 # overflows the bottom, left in place (Ignore)
  end
end
