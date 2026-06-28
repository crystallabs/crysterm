require "./spec_helper"

include Crysterm

# Regression spec for `Widget::Terminal#on_mouse` mouse-mode gating.
#
# A child enables mouse reporting with a specific xterm DECSET mode, and the
# widget must forward only the event kinds that mode asked for. The modes are
# progressive: X10 (9) = button presses only; normal (1000) adds release +
# wheel but NOT motion; button-event (1002) adds motion *while a button is
# held*; any-event (1003) adds free motion. Previously the widget forwarded
# every `Event::Mouse` whenever any tracking was active, so a child in the
# common normal mode received a flood of spurious motion reports it never
# requested.

private def screen
  Crysterm::Screen.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 80, height: 24)
end

private def mouse(action : ::Tput::Mouse::Action, button : ::Tput::Mouse::Button, x : Int32, y : Int32)
  Crysterm::Event::Mouse.new(::Tput::Mouse::Event.new(action, button, x, y))
end

describe "Widget::Terminal#on_mouse (tracking-mode gating)" do
  it "drops motion in normal mode but forwards presses, and honours button-event motion" do
    captured = [] of String
    s = screen
    term = Crysterm::Widget::Terminal.new(
      parent: s, top: 0, left: 0, width: 10, height: 4,
      handler: ->(data : String) { captured << data; nil })

    # Render once so the emulator is bootstrapped from the resolved geometry.
    s._render
    term.emulator.should_not be_nil

    # ── normal tracking (1000): motion must NOT be forwarded ──
    term.write "\e[?1000h"
    captured.clear
    term.on_mouse mouse(::Tput::Mouse::Action::Move, ::Tput::Mouse::Button::None, 2, 1)
    captured.should be_empty

    # A button press IS forwarded.
    term.on_mouse mouse(::Tput::Mouse::Action::Down, ::Tput::Mouse::Button::Left, 2, 1)
    captured.size.should eq 1

    # ── button-event tracking (1002): motion only while a button is held ──
    term.write "\e[?1002h"
    captured.clear
    term.on_mouse mouse(::Tput::Mouse::Action::Move, ::Tput::Mouse::Button::None, 3, 1)
    captured.should be_empty # free hover: still dropped

    term.on_mouse mouse(::Tput::Mouse::Action::Move, ::Tput::Mouse::Button::Left, 3, 1)
    captured.size.should eq 1 # drag motion: forwarded
  ensure
    term.try &.kill
    s.try &.destroy
  end
end
