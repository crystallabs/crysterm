require "./spec_helper"

include Crysterm

# Regression specs for the BUGS4 cursor / focus fixes:
#
#  1. `Window#reset_cursor` (formerly `#cursor_reset`) cleared `style.bg` but
#     not `style.fg`. Since `style.fg` is the single source of truth
#     `#apply_cursor` reads, a "reset" cursor kept its old color: the next
#     `#apply_cursor` (a focus change, a `#cursor_shape` call, …) re-issued the
#     stale hardware-cursor color. The OSC-112 reset done inside `#reset_cursor`
#     was thus only transient.
#  2. `_focus`'s scroll-into-view hand-rolled its math with `cur.rtop`, which is
#     relative to `cur`'s *immediate* parent — correct only for a direct child of
#     the scrollable ancestor. For a deeper descendant it omitted the intervening
#     offsets. It now delegates to `#ensure_widget_visible`, which maps via
#     absolute tops.

private def cursor_screen
  io = IO::Memory.new
  screen = Crysterm::Window.new(
    input: IO::Memory.new, output: io, error: IO::Memory.new)
  # Force determinism regardless of $TERM: pretend hardware cursor recoloring is
  # supported, and keep the cursor non-artificial so the hardware path runs.
  screen.tput.features.cursor_color = true
  screen.cursor.artificial = false
  {screen, io}
end

describe "BUGS4 Window#reset_cursor clears the cursor color (fix #1)" do
  it "nils style.fg so a later apply_cursor does not re-issue the old color" do
    screen, io = cursor_screen

    screen.cursor_color = "red"
    screen.cursor.style.fg.should eq Crysterm::Colors.convert("red")

    screen.reset_cursor
    screen.cursor.style.fg.should be_nil # the fix: fg is cleared, not just bg

    # A subsequent re-apply must restore the terminal default (OSC 112), not
    # re-emit the red set-color (OSC 12).
    mark = io.size
    screen.apply_cursor
    tail = String.new(io.to_slice[mark...io.size])
    tail.should contain("\e]112")
    tail.should_not contain("\e]12;")
  end
end

private def focus_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

describe "BUGS4 _focus scrolls a deep descendant into view (fix #2)" do
  it "reveals a focusable nested inside an intermediate container" do
    s = focus_screen
    box = Crysterm::Widget::ScrollableBox.new parent: s, top: 0, left: 0,
      width: 20, height: 8, style: Crysterm::Style.new(border: true),
      content: (1..60).map { |i| "line#{i}" }.join("\n")
    # An intermediate, non-scrollable container offset *within* the box, so the
    # target's `rtop` (relative to `inner`) differs from its content row in
    # `box` — exactly the case the old `cur.rtop` math got wrong.
    inner = Crysterm::Widget::Box.new parent: box, top: 3, left: 0,
      width: 18, height: 40
    target = Crysterm::Widget::Box.new parent: inner, keys: true,
      top: 15, left: 0, width: 5, height: 1, content: "x"
    s._render

    box.child_base.should eq 0

    s.focus target

    # The target's content row within the box (via absolute tops) must be inside
    # the visible band. The old code, using rtop==15 (relative to `inner`, not
    # `box`), would have scrolled to the wrong row, leaving the true row (18)
    # below the viewport.
    content_row = (target.atop || 0) - (box.atop || 0) - box.itop
    content_row.should eq 18
    visible = box.aheight - box.ivertical
    (box.child_base <= content_row).should be_true
    (content_row <= box.child_base + visible - 1).should be_true
  end
end
