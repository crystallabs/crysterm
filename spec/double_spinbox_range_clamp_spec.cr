require "./spec_helper"

include Crysterm

# `DoubleSpinBox#minimum=`/`#maximum=` must behave like the integer `SpinBox`
# (via `Mixin::RangedValue#set_range`) and `ProgressBar#set_range`: re-clamp the
# current value into the new range, never store an inverted range, and repaint.
#
# They used to be plain `property` setters that just overwrote the bound, so a
# `setMinimum` above (or `setMaximum` below) the current value left `value`
# outside `[minimum, maximum]` and the displayed number stale — diverging from
# Qt's `QDoubleSpinBox` and from the integer sibling.

private def dsr_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

describe "DoubleSpinBox range clamping" do
  it "re-clamps (and repaints) the value when the minimum rises above it" do
    s = dsr_screen
    d = Crysterm::Widget::DoubleSpinBox.new parent: s, minimum: 0.0, maximum: 100.0, value: 10.0
    changes = [] of Float64
    d.on(Crysterm::Event::DoubleValueChange) { |e| changes << e.value }

    d.minimum = 50.0
    d.minimum.should eq 50.0
    d.value.should eq 50.0 # pulled up into the new range
    d.formatted_value.should eq "50.00"
    changes.should eq [50.0]
  end

  it "re-clamps the value when the maximum drops below it" do
    s = dsr_screen
    d = Crysterm::Widget::DoubleSpinBox.new parent: s, minimum: 0.0, maximum: 100.0, value: 80.0
    d.maximum = 25.0
    d.maximum.should eq 25.0
    d.value.should eq 25.0
  end

  it "never stores an inverted range (a max below min collapses it, Qt setRange)" do
    s = dsr_screen
    d = Crysterm::Widget::DoubleSpinBox.new parent: s, minimum: 0.0, maximum: 100.0, value: 40.0
    d.maximum = -10.0
    d.minimum.should eq 0.0
    d.maximum.should eq 0.0
    d.value.should eq 0.0
  end
end
