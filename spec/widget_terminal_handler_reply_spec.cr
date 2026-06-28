require "./spec_helper"

include Crysterm

# Regression spec for `Widget::Terminal` in *handler* mode (no PTY).
#
# When the widget is driven by a `handler` instead of a spawned PTY, the
# emulator's *solicited* replies — cursor-position (DSR `CSI 6 n`) and device
# attributes (DA `CSI c`) — are child-bound, the same direction as keystrokes
# and mouse/focus reports. They must therefore reach the handler too.
#
# Previously `bootstrap` only wired `emulator.output` to `pty.master`, leaving
# it nil in handler mode, so `respond` silently dropped every reply and a child
# that probes the terminal at startup (e.g. vim/htop querying DA/CPR) waited
# forever for an answer.

private def screen
  Crysterm::Screen.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 80, height: 24)
end

describe "Widget::Terminal handler-mode replies" do
  it "routes emulator DSR/DA replies back to the handler" do
    captured = [] of String
    s = screen
    term = Crysterm::Widget::Terminal.new(
      parent: s, top: 0, left: 0, width: 10, height: 4,
      handler: ->(data : String) { captured << data; nil })

    # Render once so the emulator is bootstrapped from the resolved geometry
    # (and its output sink is wired to the handler).
    s._render
    term.emulator.should_not be_nil

    # Cursor-position report (DSR): a fresh emulator's cursor is at home, so the
    # reply is CPR for row 1, column 1.
    term.write "\e[6n"
    captured.join.should eq "\e[1;1R"

    # Primary device-attributes (DA): the emulator answers a VT102 identity.
    captured.clear
    term.write "\e[c"
    captured.join.should eq "\e[?6c"
  ensure
    term.try &.kill
    s.try &.destroy
  end
end
