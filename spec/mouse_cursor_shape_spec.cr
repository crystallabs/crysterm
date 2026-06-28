require "./spec_helper"

include Crysterm

# `Widget#mouse_cursor_shape=` + `Screen#set_mouse_cursor_shape`: changing the
# GUI mouse-pointer shape (xterm's OSC 22) while a widget is hovered, gated
# behind the `mouse.cursor_shape` config option. Driven headlessly over
# in-memory IOs through the public `#dispatch_mouse` entry point.

private def shape_screen(output)
  Crysterm::Screen.new(
    input: IO::Memory.new,
    output: output,
    error: IO::Memory.new)
end

private def hover(s, x, y)
  s.dispatch_mouse ::Tput::Mouse::Event.new(
    ::Tput::Mouse::Action::Move, ::Tput::Mouse::Button::None, x, y, source: :test)
end

private def drained(s, io)
  s.tput.flush
  str = io.to_s
  io.clear
  str
end

describe "Widget#mouse_cursor_shape (OSC 22 on hover)" do
  it "sets the pointer on hover-in and restores the default on hover-out when gated on" do
    buf = IO::Memory.new
    s = shape_screen buf
    s.mouse_cursor_shape = true
    Widget::Box.new parent: s, left: 0, top: 0, width: 10, height: 3,
      mouse_cursor_shape: ::Tput::MouseCursorShape::PointingHandCursor
    drained s, buf # discard any construction output

    hover s, 2, 1 # hover in
    drained(s, buf).should contain "\e]22;hand2\a"

    hover s, 50, 50 # hover out (off the widget)
    drained(s, buf).should contain "\e]22;\a"
  end

  it "does nothing when the gate (mouse.cursor_shape) is off" do
    buf = IO::Memory.new
    s = shape_screen buf
    s.mouse_cursor_shape = false
    Widget::Box.new parent: s, left: 0, top: 0, width: 10, height: 3,
      mouse_cursor_shape: ::Tput::MouseCursorShape::PointingHandCursor
    drained s, buf

    hover s, 2, 1
    drained(s, buf).should_not contain "\e]22"
  end

  it "wiring a hover shape makes the widget mouse-responsive (hit-testable)" do
    s = shape_screen IO::Memory.new
    box = Widget::Box.new parent: s, left: 0, top: 0, width: 10, height: 3,
      mouse_cursor_shape: ::Tput::MouseCursorShape::Watch
    box.wants_mouse?.should be_true
  end

  it "emits only on an actual change (no redundant sequences while staying on a widget)" do
    buf = IO::Memory.new
    s = shape_screen buf
    s.mouse_cursor_shape = true
    Widget::Box.new parent: s, left: 0, top: 0, width: 10, height: 3,
      mouse_cursor_shape: ::Tput::MouseCursorShape::PointingHandCursor
    drained s, buf

    hover s, 2, 1 # hover in -> emits
    drained(s, buf).should contain "\e]22;hand2\a"
    hover s, 3, 1 # still inside -> MouseMove, same shape, no emit
    drained(s, buf).should_not contain "\e]22"
  end
end
