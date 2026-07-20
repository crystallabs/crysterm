require "./spec_helper"

include Crysterm

# Phase-2 reactivity: auto-tracking `Reactive::Effect` (re-tracks its dependency
# set each run) and derived `Reactive::Computed`. See REACTIVE.md.

private def rx_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false,
    optimization: Crysterm::OptimizationFlag::DamageTracking)
end

describe Crysterm::Reactive::Effect do
  it "runs once immediately and re-runs when a read signal changes" do
    a = Crysterm::Reactive::Signal.new 1
    seen = [] of Int32
    Crysterm::Reactive.effect { seen << a.value }
    seen.should eq [1]
    a.value = 2
    seen.should eq [1, 2]
    a.value = 2 # unchanged: no emit, no re-run
    seen.should eq [1, 2]
  end

  it "auto-discovers dependencies without naming them" do
    a = Crysterm::Reactive::Signal.new 10
    b = Crysterm::Reactive::Signal.new 20
    sum = 0
    Crysterm::Reactive.effect { sum = a.value + b.value }
    sum.should eq 30
    a.value = 100
    sum.should eq 120
    b.value = 200
    sum.should eq 300
  end

  it "re-tracks: drops a dependency it stops reading, picks up a new one" do
    toggle = Crysterm::Reactive::Signal.new true
    a = Crysterm::Reactive::Signal.new 1
    b = Crysterm::Reactive::Signal.new 100
    log = [] of Int32
    Crysterm::Reactive.effect { log << (toggle.value ? a.value : b.value) }

    log.should eq [1] # reads toggle, a
    a.value = 2
    log.should eq [1, 2]
    b.value = 200 # b not tracked yet -> no re-run
    log.should eq [1, 2]

    toggle.value = false # re-runs, now reads toggle, b (b == 200); a is dropped
    log.should eq [1, 2, 200]
    a.value = 3 # a no longer tracked -> no re-run
    log.should eq [1, 2, 200]
    b.value = 300 # now tracked -> re-run
    log.should eq [1, 2, 200, 300]
  end

  it "de-dups repeated reads of the same signal within a run" do
    a = Crysterm::Reactive::Signal.new 1
    runs = 0
    Crysterm::Reactive.effect { runs += 1; a.value + a.value + a.value }
    runs.should eq 1
    a.value = 2 # one subscription despite three reads -> exactly one re-run
    runs.should eq 2
  end

  it "stops re-running after dispose" do
    a = Crysterm::Reactive::Signal.new 1
    seen = [] of Int32
    eff = Crysterm::Reactive.effect { seen << a.value }
    a.value = 2
    seen.should eq [1, 2]
    eff.dispose
    a.value = 3
    seen.should eq [1, 2]
    eff.disposed?.should be_true
  end

  it "runs once per batch regardless of how many reads changed" do
    a = Crysterm::Reactive::Signal.new 0
    b = Crysterm::Reactive::Signal.new 0
    runs = 0
    Crysterm::Reactive.effect { runs += 1; a.value + b.value }
    runs.should eq 1
    Crysterm::Reactive.batch do
      a.value = 1
      b.value = 1
      a.value = 2
    end
    runs.should eq 2 # one deferred run for the whole batch
  end

  it "schedules a repaint on the owner window when given one" do
    scr = rx_screen
    box = Crysterm::Widget::Box.new parent: scr, width: 20, height: 3
    count = Crysterm::Reactive::Signal.new 0
    Crysterm::Reactive.effect(box) { box.content = "e#{count.value}" }
    scr.repaint
    scr.@damage_dirty_roots.clear
    count.value = 1
    scr.@damage_dirty_roots.includes?(box).should be_true
    box.content.should eq "e1"
  end

  it "disposes automatically when its owner widget is destroyed" do
    scr = rx_screen
    box = Crysterm::Widget::Box.new parent: scr, width: 20, height: 3
    count = Crysterm::Reactive::Signal.new 0
    eff = Crysterm::Reactive.effect(box) { box.content = "e#{count.value}" }
    box.destroy
    eff.disposed?.should be_true
    count.value = 9 # must not raise or touch the destroyed widget
    box.content.should eq "e0"
  end
end

describe Crysterm::Reactive::Computed do
  it "derives a value and recomputes when a dependency changes" do
    n = Crysterm::Reactive::Signal.new 2
    doubled = Crysterm::Reactive::Computed(Int32).new { n.value * 2 }
    doubled.value.should eq 4
    n.value = 5
    doubled.value.should eq 10
  end

  it "notifies downstream effects when the derived value changes" do
    n = Crysterm::Reactive::Signal.new 2
    doubled = Crysterm::Reactive::Computed(Int32).new { n.value * 2 }
    seen = [] of Int32
    Crysterm::Reactive.effect { seen << doubled.value }
    seen.should eq [4]
    n.value = 5
    seen.should eq [4, 10]
  end

  it "does not notify downstream when the derived value is unchanged" do
    n = Crysterm::Reactive::Signal.new 3
    parity = Crysterm::Reactive::Computed(Bool).new { n.value.even? }
    runs = 0
    Crysterm::Reactive.effect { runs += 1; parity.value }
    runs.should eq 1
    n.value = 5 # 3 and 5 are both odd -> parity stays false -> no downstream run
    runs.should eq 1
    n.value = 4 # now even -> parity flips -> downstream runs
    runs.should eq 2
  end

  it "chains computeds" do
    n = Crysterm::Reactive::Signal.new 1
    a = Crysterm::Reactive::Computed(Int32).new { n.value + 1 }
    b = Crysterm::Reactive::Computed(Int32).new { a.value * 10 }
    b.value.should eq 20
    n.value = 4
    b.value.should eq 50
  end
end
