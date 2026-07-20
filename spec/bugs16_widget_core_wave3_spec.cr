require "./spec_helper"

include Crysterm

# Regression specs for BUGS16 wave-3 widget-core findings:
# B16-09, B16-12, B16-13, B16-14, B16-15.

private def wave3_screen(w = 30, h = 8)
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new,
    error: IO::Memory.new, width: w, height: h, default_quit_keys: false)
end

private def w3_row_chars(s, y, x0, x1)
  String.build { |io| (x0...x1).each { |x| io << s.lines[y][x].char } }
end

# B16-09 — `hide_cursor`/`show_cursor` on an ATTACHED but UNFOCUSED widget
# forwarded straight to the window's global hardware-cursor toggle (hiding the
# focused widget's cursor) and recorded nothing on the widget's own cursor.
# They must record always and forward only while focused.
describe "BUGS16 B16-09: widget cursor hide/show on an unfocused widget" do
  it "records on the widget's cursor without touching the global hardware cursor" do
    s = wave3_screen
    a = Widget::Box.new parent: s, top: 0, left: 0, width: 5, height: 2
    b = Widget::Box.new parent: s, top: 2, left: 0, width: 5, height: 2
    a.focus
    s.focused.should eq a
    s.show_cursor # window init leaves the hardware cursor hidden
    s.tput.cursor_hidden?.should be_false

    b.hide_cursor
    s.tput.cursor_hidden?.should be_false # widget A's cursor stays visible
    b.cursor.not_nil!._hidden.should be_true

    b.show_cursor
    s.tput.cursor_hidden?.should be_false
    b.cursor.not_nil!._hidden.should be_false
  ensure
    s.try &.destroy
  end

  it "still forwards to the window while focused" do
    s = wave3_screen
    a = Widget::Box.new parent: s, top: 0, left: 0, width: 5, height: 2
    a.focus

    a.hide_cursor
    s.tput.cursor_hidden?.should be_true
    a.cursor.not_nil!._hidden.should be_true

    a.show_cursor
    s.tput.cursor_hidden?.should be_false
    a.cursor.not_nil!._hidden.should be_false
  ensure
    s.try &.destroy
  end
end

# B16-12 — `label=` always re-placed the label on the default `:left` side, so
# refreshing the TEXT of a right-side label silently moved it to the left.
describe "BUGS16 B16-12: label= keeps the placed side" do
  it "updates the text of a right-side label without moving it" do
    s = wave3_screen
    w = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 4,
      style: Style.new(border: true)
    w.set_label "Title", :right
    lbl = w.label_widget.not_nil!
    lbl.right.should_not be_nil
    lbl.left.should be_nil

    w.label = "Title (2)"
    w.label.should eq "Title (2)"
    lbl.right.should_not be_nil # pre-fix: reset to the left side
    lbl.left.should be_nil
  ensure
    s.try &.destroy
  end
end

# B16-13 — with no padding and default (top-left) alignment, the rows reserved
# for a shown horizontal scroll bar — including the QAbstractScrollArea corner
# cell a shortened bar leaves uncovered — were never pre-filled with the
# widget's own background, leaving window-background holes.
describe "BUGS16 B16-13: reserved horizontal-bar band gets the widget background" do
  it "paints the corner cell under the two bars in the widget's bg" do
    s = wave3_screen w: 14, h: 6
    box = Crysterm::Widget::ScrollableBox.new parent: s, top: 0, left: 0, width: 12, height: 5,
      wrap_content: false,
      style: Style.new(bg: "blue"),
      horizontal_scrollbar_policy: Crysterm::Widget::ScrollBarPolicy::AsNeeded,
      content: (1..8).map { |i| "L#{i}-ABCDEFGHIJKLMNOP" }.join("\n") # wide + tall: both bars
    s._render

    box.hscrollbar_rows.should eq 1
    # The corner (last cell of the bar row) is left to the widget's own fill.
    w3_row_chars(s, 4, 11, 12).should eq " "
    corner_bg = Attr.bg(s.lines[4][11].attr)
    interior_bg = Attr.bg(s.lines[0][0].attr) # content cell carries the widget bg
    corner_bg.should eq interior_bg
  ensure
    s.try &.destroy
  end
end

# B16-14 — `last_rendered_position?` (the documented non-raising variant)
# raised `NilAssertionError` for a detached widget with a stale, unresolved
# `@lpos`: resolving the absolutes went through the raising `#window` accessor.
describe "BUGS16 B16-14: last_rendered_position? on a detached widget" do
  it "returns nil instead of raising after the widget is removed" do
    s = wave3_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 5, height: 2
    s._render
    box.lpos.should_not be_nil

    s.remove box
    box.window?.should be_nil
    box.last_rendered_position?.should be_nil
  ensure
    s.try &.destroy
  end
end

# B16-15 — `scrollable = false` froze a non-zero `@child_base` into every
# subsequent render while `scroll`/`reset_scroll`/`reclamp_scroll_index` all
# early-return on a non-scrollable widget — no API could clear it.
describe "BUGS16 B16-15: disabling scrollable resets the scroll state" do
  it "zeroes child_base so short replacement content is visible" do
    s = wave3_screen w: 12, h: 5
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 4,
      wrap_content: false
    box.scrollable = true
    box.set_content (1..20).map { |i| "line#{i}" }.join("\n")
    s._render
    box.scroll 15
    box.child_base.should be > 0

    box.scrollable = false
    box.child_base.should eq 0

    box.set_content "one line"
    s._render
    w3_row_chars(s, 0, 0, 8).should eq "one line"
  ensure
    s.try &.destroy
  end
end
