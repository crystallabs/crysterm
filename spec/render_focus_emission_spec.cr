require "./spec_helper"

include Crysterm

# Regression coverage for `Screen#_render` (`screen_rendering.cr`).
#
# `_render` repositions the focused widget's cursor at the end of every frame
# (the documented `_update_cursor` workaround for stale `lpos`). It must NOT
# also emit `Event::Focus`: that event denotes a focus *change* and is fired
# exactly once, from `screen_focus.cr#_focus`, when focus actually moves. Firing
# it on the focused widget on every render frame re-ran all of that widget's
# focus side effects (a `Widget::Terminal` reporting focus-in to its child PTY,
# a text widget re-entering `read_input`, menu/action-bar/remote focus handlers)
# once per frame — a real, observable defect.
private def render_screen
  Crysterm::Screen.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 20, height: 6)
end

describe "Screen#_render focus emission" do
  it "does not emit Event::Focus on every render frame" do
    screen = render_screen
    box = Widget::Box.new parent: screen, top: 0, left: 0, width: 10, height: 3

    # A real focus change: this legitimately emits Event::Focus exactly once
    # (before any handler is attached below).
    screen.focus box
    screen.focused.should eq box

    focus_events = 0
    box.on(Crysterm::Event::Focus) { focus_events += 1 }

    # Rendering must not be treated as a focus change.
    screen._render
    screen._render
    screen._render

    focus_events.should eq 0
  end
end
