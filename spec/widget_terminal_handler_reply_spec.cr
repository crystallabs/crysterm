require "./spec_helper"

include Crysterm

# Regression spec for `Widget::Terminal` in handler mode (no PTY).
#
# In handler mode, the emulator's solicited replies (DSR `CSI 6 n`, DA `CSI c`)
# are child-bound, same direction as keystrokes/mouse/focus reports, so they
# must reach the handler too.
#
# Previously `bootstrap` only wired `emulator.output` to `pty.master`, leaving
# it nil in handler mode: `respond` silently dropped every reply and a child
# probing the terminal at startup (vim/htop querying DA/CPR) waited forever.

private def screen
  Crysterm::Window.new(
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

    # Render once so the emulator is bootstrapped and its output sink wired to
    # the handler.
    s.repaint
    term.emulator.should_not be_nil

    # Cursor-position report: fresh emulator's cursor is at home, so reply is
    # CPR for row 1, column 1.
    term.write "\e[6n"
    captured.join.should eq "\e[1;1R"

    # Primary device-attributes: emulator answers a VT102 identity.
    captured.clear
    term.write "\e[c"
    captured.join.should eq "\e[?6c"
  ensure
    term.try &.kill
    s.try &.destroy
  end
end
