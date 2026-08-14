require "./spec_helper"

include Crysterm

# Conformance-style specs for the shared `Mixin::RangedValue` stepping/guards
# after consolidation (fixing live bugs B0.2 and
# B0.3). `ScrollBar` now shares `init_range` and the invert-aware
# `ranged_step_key`/`ranged_wheel` with `Slider`/`Dial` instead of hand-rolling
# copies that had drifted (missing the h/j/k/l keys; missing the range guard).

describe "ScrollBar range guard (B0.2)" do
  it "never stores an inverted range from the constructor" do
    s = headless_screen(default_quit_keys: true)
    sb = Crysterm::Widget::ScrollBar.new parent: s, minimum: 100, maximum: 0
    (sb.minimum <= sb.maximum).should be_true
    sb.minimum.should eq 100
    sb.maximum.should eq 100 # carried up, not inverted
    sb.value.should eq 100   # clamped into the (collapsed) range
  end

  it "keeps a normal range intact" do
    s = headless_screen(default_quit_keys: true)
    sb = Crysterm::Widget::ScrollBar.new parent: s, minimum: 0, maximum: 100, value: 40
    sb.minimum.should eq 0
    sb.maximum.should eq 100
    sb.value.should eq 40
  end
end

describe "ScrollBar vi/extra keys and inverted vertical direction (B0.3)" do
  it "responds to h/j/k/l (which the family gained but ScrollBar had missed)" do
    s = headless_screen(default_quit_keys: true)
    sb = Crysterm::Widget::ScrollBar.new parent: s, minimum: 0, maximum: 100, value: 50, height: 10
    sb.handle_key_press kp('j') # down → toward the end
    sb.value.should eq 51
    sb.handle_key_press kp('k') # up → toward the start
    sb.value.should eq 50
    sb.handle_key_press kp('h') # left → toward the start
    sb.value.should eq 49
    sb.handle_key_press kp('l') # right → toward the end
    sb.value.should eq 50
  end

  it "inverts the vertical arrows (Up decreases, Down increases)" do
    s = headless_screen(default_quit_keys: true)
    sb = Crysterm::Widget::ScrollBar.new parent: s, minimum: 0, maximum: 100, value: 50, height: 10
    sb.handle_key_press kp('\0', ::Tput::Key::Up)
    sb.value.should eq 49
    sb.handle_key_press kp('\0', ::Tput::Key::Down)
    sb.value.should eq 50
  end

  it "leaves Left/Right conventional (Left decreases, Right increases)" do
    s = headless_screen(default_quit_keys: true)
    sb = Crysterm::Widget::ScrollBar.new parent: s, minimum: 0, maximum: 100, value: 50, height: 10
    sb.handle_key_press kp('\0', ::Tput::Key::Left)
    sb.value.should eq 49
    sb.handle_key_press kp('\0', ::Tput::Key::Right)
    sb.value.should eq 50
  end
end

describe "Slider keeps the conventional (non-inverted) direction" do
  it "Up/k increase, Down/j decrease" do
    s = headless_screen(default_quit_keys: true)
    sl = Crysterm::Widget::Slider.new parent: s, minimum: 0, maximum: 100, value: 50, width: 20, height: 1
    sl.handle_key_press kp('\0', ::Tput::Key::Up)
    sl.value.should eq 51
    sl.handle_key_press kp('j')
    sl.value.should eq 50
  end
end
