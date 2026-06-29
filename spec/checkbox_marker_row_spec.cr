require "./spec_helper"

include Crysterm

# The marker-click hit-test in `Mixin::CheckMarker` (shared by `CheckBox` and
# `RadioButton`) used to check only the click's x against the three marker
# columns (`[ ]` / `( )`), ignoring y. A `Mouse` event is delivered for a click
# anywhere inside the widget's rect, so a control taller than one line — one
# with an explicit `height` (or a border) — toggled whenever its marker
# *column* was clicked on *any* row, not just the marker's own (first) content
# row. These specs pin the marker to its row.

private def cmr_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

private def cmr_down(s, x, y)
  s.dispatch_mouse(::Tput::Mouse::Event.new(
    ::Tput::Mouse::Action::Down, ::Tput::Mouse::Button::Left, x, y, source: :test))
end

describe "CheckMarker marker-click hit-test is row-aware" do
  it "toggles when the marker glyph row+column is clicked" do
    s = cmr_screen
    # A multi-row checkbox (no border): content rows 0..2, marker on row 0.
    cb = Crysterm::Widget::CheckBox.new parent: s, top: 0, left: 0, width: 20, height: 3, content: "Accept"
    s._render
    cb.checked?.should be_false

    # Click the marker glyph (`[x]` is at cols 0..2 on the first content row).
    cmr_down s, cb.aleft + 1, cb.atop
    cb.checked?.should be_true
  end

  it "does NOT toggle when the marker column is clicked on a lower row" do
    s = cmr_screen
    cb = Crysterm::Widget::CheckBox.new parent: s, top: 0, left: 0, width: 20, height: 3, content: "Accept"
    s._render
    cb.checked?.should be_false

    # Same marker column, but a row below the marker — inside the widget rect
    # yet not on the marker. Before the fix this toggled the box.
    cmr_down s, cb.aleft + 1, cb.atop + 1
    cb.checked?.should be_false
  end
end
