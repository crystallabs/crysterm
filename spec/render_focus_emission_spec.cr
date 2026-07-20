require "./spec_helper"

include Crysterm

# Regression: `Window#repaint` repositions the focused widget's cursor every
# frame (`_update_cursor` workaround for stale `lpos`), but must not emit
# `Event::FocusIn` — that denotes a focus *change*, fired once from
# `window_focus.cr#_focus`. Emitting it every frame re-ran focus side effects
# (PTY focus-in, `read_input` re-entry, menu/action-bar handlers) per frame.
private def render_screen
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 20, height: 6)
end

describe "Window#repaint focus emission" do
  it "does not emit Event::FocusIn on every render frame" do
    screen = render_screen
    box = Widget::Box.new parent: screen, top: 0, left: 0, width: 10, height: 3

    # A real focus change legitimately emits Event::FocusIn once (before any
    # handler is attached below).
    screen.focus box
    screen.focused.should eq box

    focus_events = 0
    box.on(Crysterm::Event::FocusIn) { focus_events += 1 }

    # Rendering must not be treated as a focus change.
    screen.repaint
    screen.repaint
    screen.repaint

    focus_events.should eq 0
  end
end
