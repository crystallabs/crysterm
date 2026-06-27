require "./spec_helper"

include Crysterm

# `ProgressBar` keeps its own range (Qt's `QProgressBar` is a plain `QWidget`,
# not a `QAbstractSlider`), and `minimum`/`maximum` used to be bare `Int32`
# `property`s. The generated setters mutated the bound without doing either of
# the two things `#value=` does on a change: re-clamp the value into the new
# range, and schedule a repaint. Because `#filled` (and the `%p`/`%m`/`%M`
# text) are all derived from the range, lowering `maximum` below the current
# value left the value out of range AND the rendered bar stale until some
# unrelated frame. The fix routes `minimum=`/`maximum=` through `#set_range`,
# which re-clamps and `#request_render`s.
#
# As in the checkbox repaint specs, a headless render fiber never paints, so the
# observable synchronous effect is the *scheduled* repaint (the damage mark).
private def pbr_screen
  Crysterm::Screen.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false,
    optimization: Crysterm::OptimizationFlag::DamageTracking)
end

private def repaint_scheduled?(s : Crysterm::Screen, w : Crysterm::Widget)
  s.@damage_dirty_roots.includes? w
end

describe "ProgressBar range changes re-clamp and schedule a repaint" do
  it "re-clamps the value when maximum drops below it" do
    pb = Crysterm::Widget::ProgressBar.new value: 80, minimum: 0, maximum: 100
    pb.value.should eq 80
    pb.maximum = 50
    pb.value.should eq 50 # clamped into the new range, not left at 80
    pb.maximum.should eq 50
  end

  it "re-clamps the value when minimum rises above it" do
    pb = Crysterm::Widget::ProgressBar.new value: 10, minimum: 0, maximum: 100
    pb.minimum = 40
    pb.value.should eq 40
    pb.minimum.should eq 40
  end

  it "schedules a repaint when maximum changes (filled is derived)" do
    s = pbr_screen
    pb = Crysterm::Widget::ProgressBar.new parent: s, top: 0, left: 0, width: 20, height: 1, value: 50, minimum: 0, maximum: 100
    s._render
    s.@damage_dirty_roots.clear
    repaint_scheduled?(s, pb).should be_false

    pb.maximum = 200 # value (50) stays in range but `filled` halves: must repaint
    pb.value.should eq 50
    repaint_scheduled?(s, pb).should be_true
  end

  it "never stores an inverted range" do
    pb = Crysterm::Widget::ProgressBar.new value: 50, minimum: 0, maximum: 100
    pb.maximum = -10 # below the minimum
    pb.maximum.should eq pb.minimum
  end

  it "set_range applies both bounds at once" do
    pb = Crysterm::Widget::ProgressBar.new value: 5, minimum: 0, maximum: 100
    pb.set_range 10, 20
    pb.minimum.should eq 10
    pb.maximum.should eq 20
    pb.value.should eq 10 # 5 clamped up into [10, 20]
  end
end
