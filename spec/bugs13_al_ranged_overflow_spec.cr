require "./spec_helper"

include Crysterm

# Regression specs for BUGS13 finding M12 — SpinBox stepping raised
# OverflowError at the Int32 bounds (Up at MAX, Down at MIN, PageUp's
# `@step * 10`), letting the exception escape the keypress handler and crash
# the TUI. Qt saturates; so do we now (`Mixin::RangedValue#increment/decrement`
# rescue OverflowError, and the PageUp delta saturates too).

private def ro_screen(w = 40, h = 10)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

describe "BUGS13 M12: SpinBox stepping saturates instead of overflowing" do
  it "saturates Up at maximum: Int32::MAX" do
    s = ro_screen
    spin = Widget::SpinBox.new parent: s, top: 0, left: 0, width: 10, height: 1,
      minimum: 0, maximum: Int32::MAX, value: Int32::MAX
    spin.increment # raised OverflowError before the fix
    spin.value.should eq Int32::MAX
  end

  it "saturates Down at minimum: Int32::MIN" do
    s = ro_screen
    spin = Widget::SpinBox.new parent: s, top: 0, left: 0, width: 10, height: 1,
      minimum: Int32::MIN, maximum: 0, value: Int32::MIN
    spin.decrement
    spin.value.should eq Int32::MIN
  end

  it "wraps to the opposite bound on overflow when wrapping: true" do
    s = ro_screen
    spin = Widget::SpinBox.new parent: s, top: 0, left: 0, width: 10, height: 1,
      minimum: 5, maximum: Int32::MAX, value: Int32::MAX, wrapping: true
    spin.increment
    spin.value.should eq 5
  end

  it "survives PageUp when step * 10 overflows Int32" do
    s = ro_screen
    spin = Widget::SpinBox.new parent: s, top: 0, left: 0, width: 10, height: 1,
      minimum: 0, maximum: Int32::MAX, value: 0, step: Int32::MAX // 2
    # `@step * 10` overflowed before the fix; now the delta saturates and the
    # step clamps to the range bound.
    spin.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::PageUp)
    spin.value.should eq Int32::MAX
  end

  it "survives Up-key stepping at the bound (handler path)" do
    s = ro_screen
    spin = Widget::SpinBox.new parent: s, top: 0, left: 0, width: 10, height: 1,
      minimum: 0, maximum: Int32::MAX, value: Int32::MAX
    spin.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::Up)
    spin.value.should eq Int32::MAX
    # A normal PageDown still steps by 10 line-steps.
    spin.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::PageDown)
    spin.value.should eq Int32::MAX - 10
  end
end
