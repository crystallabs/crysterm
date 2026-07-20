require "./spec_helper"

include Crysterm

# Regression spec for BUGS14 M2 (KeyMenu rows: 0 DivisionByZeroError) and
# BUGS14 M4 (SizeGrip drag math assumes an outer-corner placement).

private def bugs14_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80, height: 24, default_quit_keys: false)
end

# M2 — `KeyMenu.new(entries: [...], rows: 0)` (and `menu.rows = 0` after entries
# exist) fed `i // @rows` / `i % @rows` a zero divisor in `#build`, raising
# `DivisionByZeroError` during construction/rebuild. The setter and constructor
# now clamp `@rows` to at least 1.
describe "BUGS14 M2 KeyMenu rows clamped to >= 1" do
  it "does not raise DivisionByZeroError when constructed with rows: 0 and entries" do
    s = bugs14_screen
    entries = [
      Crysterm::Widget::Pine::KeyMenu::Entry.new("?", "Help"),
      Crysterm::Widget::Pine::KeyMenu::Entry.new("O", "Other"),
    ]
    # Pre-fix: this raised DivisionByZeroError inside #build.
    menu = Crysterm::Widget::Pine::KeyMenu.new(parent: s, bottom: 0, entries: entries, rows: 0)
    menu.rows.should eq 1
    menu.cells.size.should eq 2
  end

  it "clamps rows to >= 1 when set to 0 after entries exist" do
    s = bugs14_screen
    menu = Crysterm::Widget::Pine::KeyMenu.new(parent: s, bottom: 0, entries: [
      Crysterm::Widget::Pine::KeyMenu::Entry.new("?", "Help"),
      Crysterm::Widget::Pine::KeyMenu::Entry.new("O", "Other"),
    ])
    # Pre-fix: the setter's rebuild divided by zero.
    menu.rows = 0
    menu.rows.should eq 1
  end
end

# M4 — a `SizeGrip` placed at its target's inner corner (`bottom: 0, right: 0`,
# the documented placement) resized the target as if the grip sat on the outer
# corner, so a bordered box tracked the pointer `iright`/`ibottom` columns short.
# The fix folds in the grip's own offset from the target's outer edge.
describe "BUGS14 M4 SizeGrip inner-corner drag tracks the pointer" do
  it "keeps the outer edge under the pointer for a bordered target" do
    s = bugs14_screen
    box = Crysterm::Widget::Box.new(
      parent: s, top: 2, left: 2, width: 30, height: 10,
      style: Crysterm::Style.new(border: true))
    grip = Crysterm::Widget::SizeGrip.new(
      parent: box, bottom: 0, right: 0, width: 1, height: 1)
    s.repaint

    # Sanity: the grip sits inside the target's outer edge (inner corner), so a
    # non-trivial edge offset exists to fold in.
    edge_x = (box.aleft + box.awidth) - (grip.aleft + grip.awidth)
    edge_y = (box.atop + box.aheight) - (grip.atop + grip.aheight)
    edge_x.should be > 0
    edge_y.should be > 0

    # The grip's own outer cell (grip is 1x1).
    gx = grip.aleft + grip.awidth - 1
    gy = grip.atop + grip.aheight - 1

    data = Crysterm::DragData.new(grip)
    session = Crysterm::DragSession.new(grip, data, gx, gy, Crysterm::DragSensor::Mouse)
    grip.emit Crysterm::Event::DragStart, session

    # Drag with the pointer held on the grip (no motion). The box must keep its
    # size — pre-fix it shrank by iright/ibottom (30->29, 10->9).
    session.x = gx
    session.y = gy
    grip.emit Crysterm::Event::Drag, session
    box.width.should eq 30
    box.height.should eq 10

    # Now move the pointer 5 right and 3 down: the outer edge must follow by
    # exactly that much (35 / 13). Pre-fix it lagged by the border (34 / 12).
    session.x = gx + 5
    session.y = gy + 3
    grip.emit Crysterm::Event::Drag, session
    box.width.should eq 35
    box.height.should eq 13
  end
end
