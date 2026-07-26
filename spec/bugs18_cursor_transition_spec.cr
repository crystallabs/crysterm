require "./spec_helper"

include Crysterm

# B18-04: `Window#apply_cursor` re-derives `c.artificial` every call but managed
# neither side of the artificial<->hardware transition:
#
# (a) artificial->hardware: the hardware branch pushed shape/color but scheduled
#     no repaint, so the artificial-cursor glyph painted by a previous frame
#     stayed on screen indefinitely on an idle UI (two cursors visible).
# (b) ->artificial: the artificial branch never hid the hardware cursor, so a
#     window whose active cursor is artificial kept the terminal's own cursor
#     visible next to (or on top of) the artificial one.
#
# Plus the teardown siblings: once `apply_cursor` emits civis, `Window#leave` /
# `#leave_inline` must re-show the hardware cursor directly, because their
# `show_cursor` dispatches on the active cursor and the artificial branch never
# emits cnorm.
private def cursor_window(output = IO::Memory.new, width = 10, height = 4, inline = false, cursor = nil)
  if cursor
    Crysterm::Window.new(
      input: IO::Memory.new, output: output, error: IO::Memory.new,
      width: width, height: height, inline: inline, cursor: cursor)
  else
    Crysterm::Window.new(
      input: IO::Memory.new, output: output, error: IO::Memory.new,
      width: width, height: height, inline: inline)
  end
end

# Consumes any pending render request, so a later `doorbell_rung?` observes only
# rings produced after this call.
private def drain_doorbell(s) : Nil
  ch = s.@render_wakeup
  loop do
    select
    when ch.receive
    else
      break
    end
  end
end

# Whether a render has been requested (the coalescing doorbell holds a pending
# notification). Consumes the notification.
private def doorbell_rung?(s) : Bool
  ch = s.@render_wakeup
  select
  when ch.receive
    true
  else
    false
  end
end

describe "apply_cursor artificial<->hardware transition (B18-04)" do
  it "hides the hardware cursor when the cursor turns artificial" do
    outio = IO::Memory.new
    s = cursor_window outio
    # Start from a visible hardware cursor (enter's `hide_cursor` hid it).
    s.show_cursor
    s.tput.cursor_hidden?.should be_false
    outio.clear

    # A custom (None) shape can't be satisfied by the hardware cursor.
    s.set_cursor_shape Tput::CursorShape::None

    s.cursor.artificial?.should be_true
    # The hardware hide escape was emitted and the hidden state recorded (so
    # the per-frame cursor bracket in `draw` also stops re-showing it).
    outio.to_s.includes?("\e[?25l").should be_true
    s.tput.cursor_hidden?.should be_true
  end

  it "hides the hardware cursor for a window whose cursor is artificial from the start" do
    # Mechanism (b) end-to-end: constructor `cursor:` with a custom shape.
    # Before the fix, `enter`'s `hide_cursor` took the artificial branch (which
    # only records `_hidden`), so civis was never emitted and the terminal's
    # own cursor stayed visible for the whole session.
    c = Crysterm::Cursor.new
    c.shape = Tput::CursorShape::None
    outio = IO::Memory.new
    s = cursor_window outio, cursor: c

    s.active_cursor.artificial?.should be_true
    s.tput.cursor_hidden?.should be_true
    outio.to_s.includes?("\e[?25l").should be_true
  end

  it "schedules a repaint when switching artificial->hardware with a painted glyph" do
    s = cursor_window

    # Make the active cursor artificial and visible, then paint a frame so the
    # artificial glyph is composited and tracked (`@_acur_y >= 0`).
    s.set_cursor_shape Tput::CursorShape::None
    s.show_cursor
    s.repaint
    s.@_acur_y.should be >= 0

    drain_doorbell s

    # Switch to a hardware cursor (steady block never needs styling support).
    s.set_cursor_shape Tput::CursorShape::Block

    s.cursor.artificial?.should be_false
    # The transition scheduled the render whose `@_acur` repair erases the
    # stale glyph — before the fix nothing was scheduled and, on an idle UI,
    # the glyph persisted indefinitely.
    doorbell_rung?(s).should be_true

    # The scheduled draw repairs the painted cell and clears the tracker.
    s.repaint
    s.@_acur_y.should eq -1

    # Negative control: with no painted glyph left, a hardware re-apply must
    # not schedule spurious renders.
    drain_doorbell s
    s.set_cursor_shape Tput::CursorShape::Block
    doorbell_rung?(s).should be_false
  end

  it "leave re-shows the hardware cursor hidden for an artificial cursor" do
    outio = IO::Memory.new
    s = cursor_window outio
    s.set_cursor_shape Tput::CursorShape::None # artificial -> civis emitted
    s.tput.cursor_hidden?.should be_true
    outio.clear

    s.leave

    # `show_cursor` alone couldn't undo the hide (artificial branch never
    # reaches the terminal); the direct re-show must.
    s.tput.cursor_hidden?.should be_false
    outio.to_s.includes?("\e[?25h").should be_true
  end

  it "leave_inline re-shows the hardware cursor hidden for an artificial cursor" do
    outio = IO::Memory.new
    s = cursor_window outio, inline: true
    s.set_cursor_shape Tput::CursorShape::None
    s.tput.cursor_hidden?.should be_true
    outio.clear

    s.leave # inline surface: dispatches to leave_inline

    s.tput.cursor_hidden?.should be_false
    outio.to_s.includes?("\e[?25h").should be_true
  end
end
