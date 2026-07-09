require "./spec_helper"

include Crysterm

# Phase-1 reactivity: `Reactive::Signal` + `Reactive.bind` + `Reactive.batch`.
# Signals emit `Event::Changed`; `bind` is a managed permanent subscription that
# assigns a widget property and schedules a repaint; `batch` dedups binding runs
# across a burst of writes. See REACTIVE.md.

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

private def repaint_scheduled?(s : Crysterm::Window, w : Crysterm::Widget)
  s.@damage_dirty_roots.includes? w
end

describe Crysterm::Reactive::Signal do
  it "reads and writes a value" do
    s = Crysterm::Reactive::Signal.new 3
    s.value.should eq 3
    s.value = 7
    s.value.should eq 7
    s.get.should eq 7
    s.set 9
    s.value.should eq 9
  end

  it "emits Changed only on an actual change (change-guarded)" do
    s = Crysterm::Reactive::Signal.new 0
    n = 0
    s.on(Crysterm::Event::Changed) { n += 1 }
    s.value = 0 # unchanged: no emit
    n.should eq 0
    s.value = 1
    n.should eq 1
    s.value = 1 # unchanged: no emit
    n.should eq 1
  end

  it "update replaces the value via a block" do
    s = Crysterm::Reactive::Signal.new 10
    s.update { |v| v + 5 }
    s.value.should eq 15
  end
end

describe "Crysterm::Reactive.bind" do
  it "runs once immediately and again on every change" do
    scr = rx_screen
    box = Crysterm::Widget::Box.new parent: scr, top: 0, left: 0, width: 20, height: 3
    count = Crysterm::Reactive::Signal.new 0
    Crysterm::Reactive.bind(box, count) { box.content = "Count: #{count.value}" }
    box.content.should eq "Count: 0" # initial run
    count.value = 5
    box.content.should eq "Count: 5" # reactive update
  end

  it "watches multiple signals" do
    scr = rx_screen
    box = Crysterm::Widget::Box.new parent: scr, width: 20, height: 3
    a = Crysterm::Reactive::Signal.new "x"
    b = Crysterm::Reactive::Signal.new 1
    Crysterm::Reactive.bind(box, a, b) { box.content = "#{a.value}#{b.value}" }
    box.content.should eq "x1"
    a.value = "y"
    box.content.should eq "y1"
    b.value = 2
    box.content.should eq "y2"
  end

  it "schedules a repaint on the owner window when a bound signal changes" do
    scr = rx_screen
    box = Crysterm::Widget::Box.new parent: scr, top: 0, left: 0, width: 20, height: 3
    count = Crysterm::Reactive::Signal.new 0
    Crysterm::Reactive.bind(box, count) { box.content = "n=#{count.value}" }
    scr._render
    scr.@damage_dirty_roots.clear
    repaint_scheduled?(scr, box).should be_false

    count.value = 1
    repaint_scheduled?(scr, box).should be_true
  end

  it "disposes automatically when the owner is destroyed" do
    scr = rx_screen
    box = Crysterm::Widget::Box.new parent: scr, width: 20, height: 3
    count = Crysterm::Reactive::Signal.new 0
    binding = Crysterm::Reactive.bind(box, count) { box.content = "v#{count.value}" }
    box.content.should eq "v0"

    box.destroy
    binding.disposed?.should be_true
    count.value = 99 # must neither raise nor update the destroyed widget
    box.content.should eq "v0"
  end
end

describe "Crysterm::Reactive.batch" do
  it "runs a binding once for multiple writes inside the batch" do
    scr = rx_screen
    box = Crysterm::Widget::Box.new parent: scr, width: 20, height: 3
    count = Crysterm::Reactive::Signal.new 0
    runs = 0
    Crysterm::Reactive.bind(box, count) { runs += 1; box.content = "#{count.value}" }
    runs.should eq 1 # initial run at bind time

    Crysterm::Reactive.batch do
      count.value = 1
      count.value = 2
      count.value = 3
    end

    runs.should eq 2 # one deferred run, not three
    box.content.should eq "3"
  end

  it "still runs synchronously outside a batch" do
    scr = rx_screen
    box = Crysterm::Widget::Box.new parent: scr, width: 20, height: 3
    count = Crysterm::Reactive::Signal.new 0
    runs = 0
    Crysterm::Reactive.bind(box, count) { runs += 1; box.content = "#{count.value}" }
    count.value = 1
    count.value = 2
    runs.should eq 3 # initial + one per write
    box.content.should eq "2"
  end
end
