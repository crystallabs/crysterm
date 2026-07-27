require "./spec_helper"

include Crysterm

# `Widget#restyle` — the one-call spelling of programmatic styling's
# "mutate, then update" idiom. In-place style writes fire no widget setter,
# so on their own they are invisible to damage tracking (the widget never
# repaints); and writes through the resolved `#style` can land on a transient
# floor-highlight dup and be lost. `restyle` closes both traps: it yields the
# persistent `#state_style` and schedules a repaint after the block.
private def restyle_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false,
    optimization: Crysterm::OptimizationFlag::DamageTracking)
end

describe "Widget#restyle" do
  it "applies the in-place write and marks the widget damage-dirty" do
    s = restyle_screen
    box = Crysterm::Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 3
    s.repaint
    s.@damage_dirty_roots.clear
    s.@damage_dirty_roots.includes?(box).should be_false

    box.restyle &.fg = "#336699"

    box.state_style.fg.should eq 0x336699
    # A bare `box.state_style.fg = ...` leaves this set empty — the whole
    # reason the combinator exists.
    s.@damage_dirty_roots.includes?(box).should be_true
  ensure
    s.try &.destroy
  end

  it "writes to the persistent state style, not the transient floor-highlight dup" do
    s = restyle_screen
    btn = Crysterm::Widget::Button.new parent: s, top: 0, left: 0, width: 10, height: 1
    btn.state = Crysterm::WidgetState::Focused

    # At the unstyled floor a focused button resolves through a throwaway
    # reverse-video copy — a write through `#style` would land there and be
    # lost on the next resolution.
    btn.style.reverse?.should be_true
    btn.style.same?(btn.state_style).should be_false

    btn.restyle &.fg = "#ff8800"

    btn.state_style.fg.should eq 0xff8800
    # The write made the style visibly styled, so the reverse fallback no
    # longer applies and resolution returns the persistent object itself —
    # proving the write didn't land on the dup.
    btn.style.same?(btn.state_style).should be_true
    btn.style.fg.should eq 0xff8800
  ensure
    s.try &.destroy
  end

  it "reaches sub-styles for deep in-place mutation" do
    s = restyle_screen
    s.stylesheet = "GroupBox::title { color: #ff0000; }"
    gb = Crysterm::Widget::GroupBox.new parent: s, title: "T", width: 30, height: 8
    s.repaint
    s.@damage_dirty_roots.clear

    gb.restyle &.title.fg = "#00ff00"

    gb.state_style.title.fg.should eq 0x00ff00
    s.@damage_dirty_roots.includes?(gb).should be_true
  ensure
    s.try &.destroy
  end
end
