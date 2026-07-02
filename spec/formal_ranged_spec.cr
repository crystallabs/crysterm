require "./spec_helper"

include Crysterm

# Conformance-style specs for the shared `Mixin::RangedValue` stepping/guards
# after the FORMAL-WIDGETS consolidation (Part B / B1, fixing live bugs B0.2 and
# B0.3). `ScrollBar` now shares `init_range` and the invert-aware
# `ranged_step_key`/`ranged_wheel` with `Slider`/`Dial` instead of hand-rolling
# copies that had drifted (missing the h/j/k/l keys; missing the range guard).

private def mem_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
end

private def kp(char : Char, key : ::Tput::Key? = nil)
  Crysterm::Event::KeyPress.new char, key
end

describe "ScrollBar range guard (B0.2)" do
  it "never stores an inverted range from the constructor" do
    s = mem_screen
    sb = Crysterm::Widget::ScrollBar.new parent: s, minimum: 100, maximum: 0
    (sb.minimum <= sb.maximum).should be_true
    sb.minimum.should eq 100
    sb.maximum.should eq 100 # carried up, not inverted
    sb.value.should eq 100   # clamped into the (collapsed) range
  end

  it "keeps a normal range intact" do
    s = mem_screen
    sb = Crysterm::Widget::ScrollBar.new parent: s, minimum: 0, maximum: 100, value: 40
    sb.minimum.should eq 0
    sb.maximum.should eq 100
    sb.value.should eq 40
  end
end

describe "ScrollBar vi/extra keys and inverted vertical direction (B0.3)" do
  it "responds to h/j/k/l (which the family gained but ScrollBar had missed)" do
    s = mem_screen
    sb = Crysterm::Widget::ScrollBar.new parent: s, minimum: 0, maximum: 100, value: 50, height: 10
    sb.on_keypress kp('j') # down → toward the end
    sb.value.should eq 51
    sb.on_keypress kp('k') # up → toward the start
    sb.value.should eq 50
    sb.on_keypress kp('h') # left → toward the start
    sb.value.should eq 49
    sb.on_keypress kp('l') # right → toward the end
    sb.value.should eq 50
  end

  it "inverts the vertical arrows (Up decreases, Down increases)" do
    s = mem_screen
    sb = Crysterm::Widget::ScrollBar.new parent: s, minimum: 0, maximum: 100, value: 50, height: 10
    sb.on_keypress kp('\0', ::Tput::Key::Up)
    sb.value.should eq 49
    sb.on_keypress kp('\0', ::Tput::Key::Down)
    sb.value.should eq 50
  end

  it "leaves Left/Right conventional (Left decreases, Right increases)" do
    s = mem_screen
    sb = Crysterm::Widget::ScrollBar.new parent: s, minimum: 0, maximum: 100, value: 50, height: 10
    sb.on_keypress kp('\0', ::Tput::Key::Left)
    sb.value.should eq 49
    sb.on_keypress kp('\0', ::Tput::Key::Right)
    sb.value.should eq 50
  end
end

describe "Slider keeps the conventional (non-inverted) direction" do
  it "Up/k increase, Down/j decrease" do
    s = mem_screen
    sl = Crysterm::Widget::Slider.new parent: s, minimum: 0, maximum: 100, value: 50, width: 20, height: 1
    sl.on_keypress kp('\0', ::Tput::Key::Up)
    sl.value.should eq 51
    sl.on_keypress kp('j')
    sl.value.should eq 50
  end
end
