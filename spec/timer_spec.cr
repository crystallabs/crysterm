require "./spec_helper"

# `Timer`'s named constructors (`.single_shot`, `.every`) and its QTimer-like
# no-autostart contract, plus `Mixin::TimedDismissal`'s cancellable one-shot.

private class DismissProbe
  include Crysterm::Mixin::TimedDismissal

  def arm(span : Time::Span, &block : ->) : Crysterm::Timer
    after(span, &block)
  end

  def bump : Int32
    bump_dismiss_gen
  end
end

describe Crysterm::Timer do
  it "does not autostart from any constructor" do
    Crysterm::Timer.new(1.millisecond).running?.should be_false
    Crysterm::FrameClock.ticker(1.millisecond) { }.running?.should be_false
    Crysterm::FrameClock.tween(1.millisecond, duration: 1.second) { }.running?.should be_false
  end

  describe ".single_shot" do
    it "fires the block exactly once, not at t≈0, then stops" do
      fired = 0
      t = Crysterm::Timer.single_shot(15.milliseconds) { fired += 1 }
      t.running?.should be_true
      Fiber.yield
      fired.should eq 0 # first (and only) tick lands at t≈span, not t≈0
      sleep 60.milliseconds
      fired.should eq 1
      t.running?.should be_false
    end

    it "is cancellable via #stop before it fires" do
      fired = 0
      t = Crysterm::Timer.single_shot(15.milliseconds) { fired += 1 }
      t.stop
      sleep 60.milliseconds
      fired.should eq 0
      t.running?.should be_false
    end
  end

  describe ".every" do
    it "repeats until the block stops the yielded timer" do
      calls = 0
      Crysterm::Timer.every(2.milliseconds) do |t|
        calls += 1
        t.stop if calls >= 3
      end
      sleep 60.milliseconds
      calls.should eq 3
    end

    it "stops by itself after `times:` calls" do
      calls = 0
      t = Crysterm::Timer.every(2.milliseconds, times: 4) { calls += 1 }
      sleep 60.milliseconds
      calls.should eq 4
      t.running?.should be_false
    end

    it "rejects a non-positive times:" do
      expect_raises(ArgumentError) do
        Crysterm::Timer.every(2.milliseconds, times: 0) { }
      end
    end
  end
end

describe Crysterm::Mixin::TimedDismissal do
  it "runs the armed block after the span" do
    probe = DismissProbe.new
    fired = 0
    probe.arm(5.milliseconds) { fired += 1 }
    sleep 60.milliseconds
    fired.should eq 1
  end

  it "cancels a pending timer when the generation is bumped" do
    probe = DismissProbe.new
    fired = 0
    probe.arm(15.milliseconds) { fired += 1 }
    probe.bump # supersede: e.g. a newer message, or teardown
    sleep 60.milliseconds
    fired.should eq 0
  end
end
