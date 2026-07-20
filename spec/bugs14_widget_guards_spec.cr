require "./spec_helper"

include Crysterm

# BUGS14 W1/W2/W3 — divide-by-zero / Int32-overflow guards on public, unvalidated
# widget inputs that otherwise crash a background/render fiber.
#
# W1: Media#speed = 0 makes the animation/stream pacers divide by zero and
#     overflow the integer/Time::Span conversion (OverflowError). The setter now
#     clamps a non-positive/non-finite speed to native (1.0).
# W2: Box#pulse(period: 0.seconds) made `half == 0`, so the first tick's
#     `elapsed % (2.0 * half)` (x % 0.0) raised DivisionByZeroError in the ticker
#     fiber. The period is now floored at 0.001.
# W3: a >=10-digit offset in a string position/size expression overflowed Int32
#     on `off * 10` (OverflowError) in the per-frame render path. The accumulator
#     is now clamped.

private def guard_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

describe "BUGS14 widget guards (W1/W2/W3)" do
  it "W1: Media#speed= clamps 0 to native (1.0), no divide-by-zero" do
    s = guard_screen
    media = Crysterm::Widget::Media::Ansi.new parent: s, top: 0, left: 0, width: 8, height: 4
    media.speed = 0.0
    media.speed.should eq 1.0
    # Negative and non-finite likewise floor to native.
    media.speed = -5.0
    media.speed.should eq 1.0
    media.speed = Float64::INFINITY
    media.speed.should eq 1.0
    media.speed = Float64::NAN
    media.speed.should eq 1.0
    # A genuine positive value is preserved.
    media.speed = 2.5
    media.speed.should eq 2.5
  end

  it "W2: Box#pulse(period: 0.seconds) does not raise DivisionByZeroError" do
    s = guard_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 4
    anim = box.pulse(period: 0.seconds) # must not raise
    anim.should_not be_nil
    box.stop_fade
  end

  it "W3: huge string-position offsets render without OverflowError" do
    s = guard_screen
    Widget::Box.new parent: s, left: "50%+9999999999", top: "center+3000000000",
      width: 4, height: 2
    s.repaint # the Dim offset parser saturates; resolving must not raise OverflowError
  end
end
