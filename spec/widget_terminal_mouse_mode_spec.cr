require "./spec_helper"

include Crysterm

# Regression spec for `Widget::Terminal#handle_mouse` mouse-mode gating.
#
# A child enables mouse reporting via an xterm DECSET mode, and the widget must
# forward only the event kinds that mode asked for. Modes are progressive: X10
# (9) = presses only; normal (1000) adds release + wheel but not motion;
# button-event (1002) adds motion while a button is held; any-event (1003)
# adds free motion. Forwarding every `Event::Mouse` while any tracking is
# active would flood normal-mode children with motion reports.

private def mouse(action : ::Tput::Mouse::Action, button : ::Tput::Mouse::Button, x : Int32, y : Int32)
  Crysterm::Event::Mouse.new(::Tput::Mouse::Event.new(action, button, x, y))
end

describe "Widget::Terminal#handle_mouse (tracking-mode gating)" do
  it "drops motion in normal mode but forwards presses, and honours button-event motion" do
    captured = [] of String
    s = headless_screen(80, 24, default_quit_keys: true)
    term = Crysterm::Widget::Terminal.new(
      parent: s, top: 0, left: 0, width: 10, height: 4,
      handler: ->(data : String) { captured << data; nil })

    # Render once so the emulator bootstraps from resolved geometry.
    s.repaint
    term.emulator.should_not be_nil

    # ── normal tracking (1000): motion not forwarded ──
    term.write "\e[?1000h"
    captured.clear
    term.handle_mouse mouse(::Tput::Mouse::Action::Move, ::Tput::Mouse::Button::None, 2, 1)
    captured.should be_empty

    # Button press is forwarded.
    term.handle_mouse mouse(::Tput::Mouse::Action::Down, ::Tput::Mouse::Button::Left, 2, 1)
    captured.size.should eq 1

    # ── button-event tracking (1002): motion only while a button is held ──
    term.write "\e[?1002h"
    captured.clear
    term.handle_mouse mouse(::Tput::Mouse::Action::Move, ::Tput::Mouse::Button::None, 3, 1)
    captured.should be_empty # free hover: still dropped

    term.handle_mouse mouse(::Tput::Mouse::Action::Move, ::Tput::Mouse::Button::Left, 3, 1)
    captured.size.should eq 1 # drag motion: forwarded
  ensure
    term.try &.kill
    s.try &.destroy
  end
end
