require "./spec_helper"

include Crysterm

# Removing a hovered widget that owns a GUI mouse-pointer shape (OSC 22 — see
# `Widget#mouse_cursor_shape=`) must restore the terminal-default pointer, just
# as the widget's own `Hide` handler does when it vanishes under the pointer.
#
# A removal emits no `MouseOut`, so without `Window#remove` restoring it the
# pointer stays stuck in the detached widget's shape. Driven headlessly over
# in-memory IOs through the public `#dispatch_mouse`/`#remove` entry points.

private def rmcs_screen(output)
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: output,
    error: IO::Memory.new)
end

private def rmcs_hover(s, x, y)
  s.dispatch_mouse ::Tput::Mouse::Event.new(
    ::Tput::Mouse::Action::Move, ::Tput::Mouse::Button::None, x, y, source: :test)
end

private def rmcs_drained(s, io)
  s.tput.flush
  str = io.to_s
  io.clear
  str
end

describe "Window#remove (GUI mouse-pointer shape)" do
  it "restores the default pointer when a hovered shape-owning widget is removed" do
    buf = IO::Memory.new
    s = rmcs_screen buf
    s.mouse_cursor_shape = true
    box = Widget::Box.new parent: s, left: 0, top: 0, width: 10, height: 3,
      mouse_cursor_shape: ::Tput::MouseCursorShape::PointingHandCursor
    rmcs_drained s, buf # discard construction output

    rmcs_hover s, 2, 1 # hover in -> pushes the hand pointer
    rmcs_drained(s, buf).should contain "\e]22;hand2\a"
    s.hovered.should eq box

    s.remove box                                   # no MouseOut is emitted by a removal
    rmcs_drained(s, buf).should contain "\e]22;\a" # default pointer restored
    s.hovered.should be_nil
  end
end
