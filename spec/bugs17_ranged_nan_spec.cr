require "./spec_helper"

include Crysterm

# B17-19: `Mixin::RangedValue(Float64)` (as included by `DoubleSpinBox`) must
# sanitize non-finite input at ingestion, matching `PercentRange#assign_completable`
# and the B16-38 convention.
#
# NaN survives `clamp` (every comparison with NaN is false) and never equals
# `@value`, so before the fix `value = Float64::NAN` stored NaN — the box rendered
# "nan" and re-fired `Event::DoubleValueChanged(NaN)` on every step. `set_range`
# with a non-finite bound likewise stored NaN bounds, wedging clamp/stepping.

private def rnan_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

describe "B17-19 RangedValue(Float64) non-finite sanitization" do
  it "value = NaN falls back to the minimum (a finite value) and does not render \"nan\"" do
    s = rnan_screen
    d = Crysterm::Widget::DoubleSpinBox.new parent: s, minimum: 5.0, maximum: 100.0, value: 10.0
    changes = [] of Float64
    d.on(Crysterm::Event::DoubleValueChanged) { |e| changes << e.value }

    d.value = Float64::NAN

    d.value.finite?.should be_true
    d.value.should eq 5.0 # fell back to minimum
    d.formatted_value.should eq "5.00"
    d.formatted_value.should_not contain "nan"
    changes.should eq [5.0]
  end

  it "value = Infinity also falls back to the minimum" do
    s = rnan_screen
    d = Crysterm::Widget::DoubleSpinBox.new parent: s, minimum: 5.0, maximum: 100.0, value: 10.0
    d.value = Float64::INFINITY
    d.value.finite?.should be_true
    d.value.should eq 5.0
  end

  it "set_range with a NaN bound is a no-op (bounds and value unchanged)" do
    s = rnan_screen
    d = Crysterm::Widget::DoubleSpinBox.new parent: s, minimum: 0.0, maximum: 100.0, value: 40.0

    d.set_range(Float64::NAN, 10.0)

    d.minimum.should eq 0.0
    d.maximum.should eq 100.0
    d.value.should eq 40.0
    d.minimum.finite?.should be_true
    d.maximum.finite?.should be_true
  end

  it "leaves the Int32 SpinBox behavior unchanged" do
    s = rnan_screen
    i = Crysterm::Widget::SpinBox.new parent: s, minimum: 0, maximum: 100, value: 40
    i.value = 150
    i.value.should eq 100 # still clamps
    i.set_range(20, 80)
    i.minimum.should eq 20
    i.maximum.should eq 80
    i.value.should eq 80
  end
end
