require "./spec_helper"

include Crysterm

private def mem_screen
  Crysterm::Screen.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
end

# `Mixin::RangedValue` must never store an inverted `minimum > maximum` range:
# the value clamp (and `#value_span`/the percent helpers) assume `min <= max`,
# and an inverted range would force the value to a nonsensical bound and emit
# spurious change events. Mirrors Qt, where the bounds adjust to stay ordered.
describe "Crysterm::Mixin::RangedValue inverted-range guard" do
  it "carries the maximum up when the new minimum exceeds it (Qt setMinimum)" do
    s = mem_screen
    sb = Crysterm::Widget::SpinBox.new parent: s, minimum: 0, maximum: 100, value: 50

    sb.minimum = 150
    # Range stays ordered (collapsed to the single value), never inverted.
    sb.minimum.should eq 150
    sb.maximum.should eq 150
    (sb.minimum <= sb.maximum).should be_true
    sb.value.should eq 150
  end

  it "carries the minimum down when the new maximum is below it (Qt setMaximum)" do
    s = mem_screen
    sb = Crysterm::Widget::SpinBox.new parent: s, minimum: 50, maximum: 100, value: 80

    sb.maximum = 10
    sb.minimum.should eq 10
    sb.maximum.should eq 10
    (sb.minimum <= sb.maximum).should be_true
    sb.value.should eq 10
  end

  it "collapses an inverted range passed straight to #set_range" do
    s = mem_screen
    sb = Crysterm::Widget::SpinBox.new parent: s, minimum: 0, maximum: 100, value: 40

    sb.set_range 80, 20
    (sb.minimum <= sb.maximum).should be_true
    sb.minimum.should eq 80
    sb.maximum.should eq 80
    sb.value.should eq 80
  end

  it "keeps a valid range and value usable after the bounds were re-ordered" do
    s = mem_screen
    sb = Crysterm::Widget::SpinBox.new parent: s, minimum: 0, maximum: 100, value: 50

    # Set bounds in the "wrong" order (min before max) — a plausible mistake.
    sb.minimum = 150
    sb.maximum = 200

    sb.minimum.should eq 150
    sb.maximum.should eq 200
    sb.value = 175
    sb.value.should eq 175
  end
end
