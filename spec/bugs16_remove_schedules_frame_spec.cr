require "./spec_helper"

include Crysterm

# BUGS16.md #B16-08: removing/destroying a widget performed the unlink, unregistered
# input and emitted events, but never rang the render doorbell. On an idle UI a
# key/mouse handler that removed a widget left it fully painted (while already
# unclickable/unfocusable) until some unrelated mutation forced the next frame.
# The centralized fix rings the doorbell from the structural-change damage hooks
# (`_damage_invalidate_structure` on both Widget and Window), which every
# add/remove/reparent already funnels through.

private def b16_08_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

# Non-blocking receive on the render doorbell: true iff a frame is pending.
# Consumes one token.
private def frame_scheduled?(w) : Bool
  select
  when w.@render_wakeup.receive
    true
  else
    false
  end
end

# Empties the coalescing doorbell so a later `frame_scheduled?` observes only
# tokens rung after this point.
private def drain_frames(w) : Nil
  loop do
    select
    when w.@render_wakeup.receive
      # keep draining
    else
      return
    end
  end
end

describe "Removing/destroying a widget schedules a frame (#B16-08)" do
  it "parent.remove(child) rings the render doorbell" do
    s = b16_08_screen
    box = Crysterm::Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 5
    child = Crysterm::Widget::Box.new parent: box, top: 0, left: 0, width: 5, height: 2
    s.repaint
    drain_frames s

    box.remove child
    frame_scheduled?(s).should be_true
  end

  it "child.parent = nil rings the render doorbell" do
    s = b16_08_screen
    box = Crysterm::Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 5
    child = Crysterm::Widget::Box.new parent: box, top: 0, left: 0, width: 5, height: 2
    s.repaint
    drain_frames s

    child.parent = nil
    frame_scheduled?(s).should be_true
  end

  it "child.destroy rings the render doorbell" do
    s = b16_08_screen
    box = Crysterm::Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 5
    child = Crysterm::Widget::Box.new parent: box, top: 0, left: 0, width: 5, height: 2
    s.repaint
    drain_frames s

    child.destroy
    frame_scheduled?(s).should be_true
  end

  it "removing a top-level widget from the window rings the render doorbell" do
    s = b16_08_screen
    box = Crysterm::Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 5
    s.repaint
    drain_frames s

    s.remove box
    frame_scheduled?(s).should be_true
  end

  it "destroying a top-level widget rings the render doorbell" do
    s = b16_08_screen
    box = Crysterm::Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 5
    s.repaint
    drain_frames s

    box.destroy
    frame_scheduled?(s).should be_true
  end

  it "a runtime append (the same structural hook) rings the render doorbell" do
    s = b16_08_screen
    box = Crysterm::Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 5
    s.repaint
    drain_frames s

    Crysterm::Widget::Box.new parent: box, top: 0, left: 0, width: 5, height: 2
    frame_scheduled?(s).should be_true
  end
end
