require "./spec_helper"

include Crysterm

# Phase-5 reactivity: the `reactive_property` macro — signal-backed widget
# properties. `obj.prop = x` notifies bindings/effects, marks the widget dirty,
# and schedules a repaint; `obj.prop` read inside an effect auto-tracks; and
# `obj.prop_signal` is the bindable Signal. See REACTIVE.md.

private class RPBox < Crysterm::Widget::Box
  # ameba:disable Lint/UselessAssign
  reactive_property caption : String = "untitled"
  # ameba:disable Lint/UselessAssign
  reactive_property count : Int32 = 0, Changed
end

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

describe "reactive_property" do
  it "reads the default and writes new values" do
    scr = rx_screen
    w = RPBox.new parent: scr, width: 20, height: 3
    w.caption.should eq "untitled"
    w.caption = "hello"
    w.caption.should eq "hello"
  end

  it "exposes a stable backing Signal via #<name>_signal" do
    scr = rx_screen
    w = RPBox.new parent: scr, width: 20, height: 3
    w.caption_signal.should be_a Crysterm::Reactive::Signal(String)
    w.caption_signal.should be w.caption_signal # lazily created once, then reused
    w.caption = "x"
    w.caption_signal.value.should eq "x"
  end

  it "is trackable: an Effect reading the property re-runs on change" do
    scr = rx_screen
    w = RPBox.new parent: scr, width: 20, height: 3
    seen = [] of String
    Crysterm::Reactive.effect { seen << w.caption }
    seen.should eq ["untitled"]
    w.caption = "hello"
    seen.should eq ["untitled", "hello"]
  end

  it "is bindable via its signal" do
    scr = rx_screen
    w = RPBox.new parent: scr, width: 20, height: 3
    other = Crysterm::Widget::Box.new parent: scr, width: 20, height: 3
    Crysterm::Reactive.bind(other, w.caption_signal) { other.content = "cap=#{w.caption}" }
    other.content.should eq "cap=untitled"
    w.caption = "x"
    other.content.should eq "cap=x"
  end

  it "marks the widget dirty and schedules a repaint on change" do
    scr = rx_screen
    w = RPBox.new parent: scr, width: 20, height: 3
    scr._render
    scr.@damage_dirty_roots.clear
    w.caption = "changed"
    scr.@damage_dirty_roots.includes?(w).should be_true
  end

  it "is change-guarded: assigning the same value does nothing" do
    scr = rx_screen
    w = RPBox.new parent: scr, width: 20, height: 3
    w.caption = "same"
    runs = 0
    Crysterm::Reactive.effect { runs += 1; w.caption }
    runs.should eq 1

    scr._render
    scr.@damage_dirty_roots.clear
    w.caption = "same"                            # unchanged
    scr.@damage_dirty_roots.empty?.should be_true # no repaint
    runs.should eq 1                              # no effect re-run
  end

  it "emits an optional widget-level event when declared" do
    scr = rx_screen
    w = RPBox.new parent: scr, width: 20, height: 3
    n = 0
    w.on(Crysterm::Event::Changed) { n += 1 }
    w.count = 5
    n.should eq 1
    w.count = 5 # guarded: no emit
    n.should eq 1
    w.count.should eq 5
  end
end
