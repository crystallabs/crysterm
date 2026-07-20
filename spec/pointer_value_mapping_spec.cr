require "./spec_helper"

include Crysterm

# FORMAL-WIDGETS Part B / B1.3 — the pointer→value mapping is single-sourced:
# the axis extraction (`Mixin::TrackGeometry#pointer_offset`, shared by `Slider`
# and `ProgressBar`) and the value formula (`AbstractSlider#value_at`, shared by
# `Slider` and `ScrollBar`). This pins that a press maps a pointer position to the
# expected value for the whole family, and the deliberate difference the lift
# reconciled: `Slider` fills bottom→top (vertical axis inverted) while a vertical
# `ScrollBar` grows top→bottom.
#
# Spans are chosen so each track cell is exactly one round value step (px span 11,
# value span 110 → 10/cell), keeping the assertions exact. Mouse hit-testing reads
# the painted `lpos`, so each widget is rendered before the synthetic press.

private def pvm_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

private def press(s, x, y)
  s.repaint
  s.dispatch_mouse ::Tput::Mouse::Event.new(
    ::Tput::Mouse::Action::Down, ::Tput::Mouse::Button::Left, x, y, source: :test)
end

describe "pointer→value mapping (FORMAL-WIDGETS B1.3)" do
  it "maps a press along a horizontal Slider to the value at that cell" do
    s = pvm_screen
    sl = Widget::Slider.new parent: s, top: 0, left: 0, width: 12, height: 1,
      minimum: 0, maximum: 110, value: 0
    press s, 0, 0
    sl.value.should eq 0
    press s, 5, 0
    sl.value.should eq 50
    press s, 11, 0
    sl.value.should eq 110
  end

  it "inverts the vertical Slider axis (top = maximum, bottom = minimum)" do
    s = pvm_screen
    sl = Widget::Slider.new parent: s, top: 0, left: 0, width: 1, height: 12,
      minimum: 0, maximum: 110, value: 0, orientation: :vertical
    press s, 0, 0
    sl.value.should eq 110 # top is the maximum
    press s, 0, 11
    sl.value.should eq 0 # bottom is the minimum
  end

  it "maps a press along a horizontal ScrollBar with the shared formula (no inversion)" do
    s = pvm_screen
    sb = Widget::ScrollBar.new parent: s, top: 0, left: 0, width: 12, height: 1,
      minimum: 0, maximum: 110, value: 0, orientation: :horizontal
    press s, 0, 0
    sb.value.should eq 0
    press s, 11, 0
    sb.value.should eq 110
  end

  it "maps a press along a horizontal ProgressBar to a fill percentage" do
    s = pvm_screen
    pb = Widget::ProgressBar.new parent: s, top: 0, left: 0, width: 12, height: 1,
      minimum: 0, maximum: 100, value: 0, mouse: true
    press s, 11, 0
    pb.percent.should eq 100
    press s, 0, 0
    pb.percent.should eq 0
  end
end
