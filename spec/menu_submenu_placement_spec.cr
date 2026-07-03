require "./spec_helper"

include Crysterm

# Submenu placement (FORMAL-WIDGETS Part A Piece 3, via `Overlay.place_child`):
# a submenu floats to the right of its parent row, flips to the left only when
# it can't fit on the right (parent near the screen's right edge), stays
# on-window, and no longer drifts by the window inset on a padded window (its
# `left`/`top` are window-content-relative, but the anchor is absolute).

private def msp_screen(*, padding = nil)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 80, height: 24, padding: padding, default_quit_keys: false)
end

private def msp_menu(s)
  m = Crysterm::Widget::Menu.new(parent: s)
  m.add("New") { }
  m.add_menu "Recent", [Crysterm::Action.new("old-1"), Crysterm::Action.new("old-2"), Crysterm::Action.new("old-3")]
  m
end

private def msp_open_sub(s, m, x, y)
  m.popup x, y
  s._render
  m.selekt 1
  m.hover_item 1 # opens the "Recent" submenu
  s._render
  m.@submenu_open.not_nil!
end

describe "Menu submenu placement" do
  it "floats to the right of the parent, adjacent to its right edge" do
    s = msp_screen
    m = msp_menu s
    sub = msp_open_sub s, m, 6, 2

    # Right of the parent, within a cell of its right edge (the shared-divider
    # border overlap is at most 1).
    ((m.aleft + m.awidth) - sub.aleft).abs.should be <= 1
    sub.aleft.should be >= m.aleft
    (sub.aleft + sub.awidth).should be <= s.awidth
  end

  it "flips to the left when the parent sits near the right edge" do
    s = msp_screen
    m = msp_menu s
    sub = msp_open_sub s, m, 74, 2 # parent clamps against the right edge

    # No room on the right → opens to the left of the parent, still on-window.
    (sub.aleft + sub.awidth).should be <= m.aleft + 1
    sub.aleft.should be >= 0
  end

  it "stays adjacent with no inset drift on a padded window" do
    s = msp_screen padding: 2
    m = msp_menu s
    sub = msp_open_sub s, m, 6, 2

    ((m.aleft + m.awidth) - sub.aleft).abs.should be <= 1
    (sub.aleft + sub.awidth).should be <= s.awidth
  end
end
