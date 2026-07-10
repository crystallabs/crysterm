require "./spec_helper"

include Crysterm

# BUGS13 W4 — the CSR scroll fast path (Widget#scroll, widget_scrolling.cr;
# also Widget#render_line_shift, widget_content.cr) passed the widget's
# painted top/bottom rows to Window#delete_line/insert_line UNCLAMPED, while
# `clean_sides`'s full-width shortcut returns true before any vertical bounds
# check. A full-width scrollable extending past the screen edge then mutated
# the window buffer out of bounds: past the bottom raised IndexError
# mid-mutation (leaving `@lines` permanently short), and a negative top made
# `delete_at` wrap around and evict BOTTOM rows (persistent buffer/terminal
# desync). Off-screen rows can't be CSR-scrolled; the path must fall through
# to a normal repaint.

private def csr_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new,
    error: IO::Memory.new, width: 40, height: 12)
end

private def row_chars(s, y)
  s.lines[y].size.times.map { |x| s.lines[y][x].char }.to_a
end

describe "BUGS13 W4: CSR scroll fast path bounds" do
  it "scrolling a full-width widget extending past the bottom edge does not corrupt the buffer" do
    s = csr_screen
    w = Widget::Box.new parent: s, top: 3, left: 0, width: "100%", height: "100%",
      scrollable: true
    w.set_content((1..60).map { |i| "line #{i}" }.join('\n'))
    s._render

    before = s.lines.size
    # Move child_base (always: true forces a base shift) — reaches the CSR
    # branch since the widget is full-width (clean_sides shortcut).
    w.scroll(1, true) # must not raise IndexError
    w.child_base.should be > 0
    s.lines.size.should eq before
    s.lines.size.should eq s.aheight
  ensure
    s.try &.destroy
  end

  it "scrolling a full-width widget with a negative top does not evict bottom rows" do
    s = csr_screen
    w = Widget::Box.new parent: s, top: -3, left: 0, width: "100%", height: "100%",
      scrollable: true
    w.set_content((1..60).map { |i| "line #{i}" }.join('\n'))
    # A marker widget on the rows BELOW the (clipped) scrollable: buffer
    # corruption from a wrapped negative delete_at shifts these rows.
    Widget::Box.new parent: s, top: 10, left: 0, width: "100%", height: 2,
      content: "MARKER-A\nMARKER-B"
    s._render

    bottom1 = row_chars(s, 10)
    bottom2 = row_chars(s, 11)

    w.scroll(1, true) # must not touch buffer rows via a wrapped index
    w.child_base.should be > 0
    s.lines.size.should eq s.aheight
    row_chars(s, 10).should eq bottom1
    row_chars(s, 11).should eq bottom2
  ensure
    s.try &.destroy
  end

  it "scrolling back up (insert_line path) past the bottom edge is safe too" do
    s = csr_screen
    w = Widget::Box.new parent: s, top: 3, left: 0, width: "100%", height: "100%",
      scrollable: true
    w.set_content((1..60).map { |i| "line #{i}" }.join('\n'))
    s._render
    w.scroll(5, true)
    w.child_base.should be > 0
    s._render

    before = s.lines.size
    w.scroll(-1, true) # insert_line direction; must not raise
    s.lines.size.should eq before
  ensure
    s.try &.destroy
  end

  it "a fully on-screen full-width scrollable still scrolls (fast path or repaint)" do
    s = csr_screen
    w = Widget::Box.new parent: s, top: 0, left: 0, width: "100%", height: 6,
      scrollable: true
    w.set_content((1..40).map { |i| "line #{i}" }.join('\n'))
    s._render

    w.scroll(1, true)
    w.child_base.should be > 0
    s.lines.size.should eq s.aheight
  ensure
    s.try &.destroy
  end

  it "Widget#insert_line's render shift is safe on a widget extending past the bottom" do
    s = csr_screen
    w = Widget::Box.new parent: s, top: 3, left: 0, width: "100%", height: "100%",
      scrollable: true
    w.set_content((1..20).map { |i| "line #{i}" }.join('\n'))
    s._render

    before = s.lines.size
    w.insert_line 1, "inserted" # render_line_shift → window.insert_line
    s.lines.size.should eq before
  ensure
    s.try &.destroy
  end
end
