require "./spec_helper"

include Crysterm

# A top-level, full-width scrollable box over a 40x12 window: rows 0..5 are its
# painted band, so a one-row scroll takes the CSR (DECSTBM + IL/DL) fast path.
private def b20_scroll_box(s : Crysterm::Window) : Crysterm::Widget::Box
  w = Widget::Box.new parent: s, top: 0, left: 0, width: "100%", height: 6,
    scrollable: true
  w.set_content((1..40).map { |i| "line #{i}" }.join('\n'))
  w
end

describe "CSR line-op scrolling" do
  it "leaves Tput's tracked cursor where the physical cursor stays" do
    s = headless_screen(40, 12)
    w = b20_scroll_box s
    s.repaint
    outbuf = s.output.as(IO::Memory)

    s.tput.cursor_pos 8, 5
    outbuf.clear
    w.scroll(1, true)

    # The buffered ops home the cursor, but they reach the terminal inside
    # the frame's cursor save/restore bracket.
    s.tput.cursor.x.should eq 5
    s.tput.cursor.y.should eq 8

    s.repaint
    # The scroll did go through the line ops.
    outbuf.to_s.matches?(/\e\[\d+;\d+r/).should be_true
    s.tput.cursor.x.should eq 5
    s.tput.cursor.y.should eq 8
  ensure
    s.try &.destroy
  end

  it "records the scrolled-in row as bare in the flushed mirror under a custom default_attr" do
    s = headless_screen(40, 12)
    red = Attr.pack(0, Attr::COLOR_DEFAULT, Attr.pack_color(0xAA0000))
    s.default_attr = red
    w = b20_scroll_box s
    s.repaint

    # Scrolling down by one deletes the band's top row; the blank row comes in
    # at its bottom (row 5).
    w.scroll(1, true)

    # The terminal's own dl scrolled in a bare blank row, not a red one.
    s.flushed_lines[5][0].attr.should eq Window::DEFAULT_ATTR
    s.flushed_lines[5][39].attr.should eq Window::DEFAULT_ATTR
    # The desired row carries the window fill, and is drawn against it.
    s.cell_rows[5][0].attr.should eq red
    s.cell_rows[5].dirty.should be_true
  ensure
    s.try &.destroy
  end
end

describe "Window cell buffers" do
  it "follow a size assigned through width=/height= on the next frame" do
    s = headless_screen(40, 10)
    Widget::Box.new parent: s, top: 0, left: 0, width: "100%", height: "100%",
      content: "x"
    s.repaint
    s.cell_rows.size.should eq 10

    s.height = 6
    s.repaint
    s.cell_rows.size.should eq 6
    s.flushed_lines.size.should eq 6

    s.width = 30
    s.repaint
    s.cell_rows[0].size.should eq 30
    s.flushed_lines[0].size.should eq 30
  ensure
    s.try &.destroy
  end
end

describe "artificial cursor placement" do
  it "paints the cursor at the caret's new cell in the frame that moves the widget" do
    s = headless_screen(40, 8)
    le = Widget::LineEdit.new parent: s, top: 1, left: 2, width: 20, height: 1
    le.focus
    c = s.active_cursor
    c.artificial = true
    c.hidden = false
    c.state = 1
    s.repaint
    x0 = s.tput.cursor.x
    y0 = s.tput.cursor.y
    s.capture_cursor_overlay(x0, y0).nil?.should be_false

    # No keystroke: only the widget's geometry changes.
    le.left = 12
    s.repaint

    s.tput.cursor.x.should eq x0 + 10
    s.tput.cursor.y.should eq y0
    s.capture_cursor_overlay(x0 + 10, y0).nil?.should be_false
    s.capture_cursor_overlay(x0, y0).nil?.should be_true
  ensure
    s.try &.destroy
  end
end

describe "Window#prompt / #ask" do
  it "refuse to park the render fiber when called from a posted job" do
    s = headless_screen(40, 10)
    raised : Exception? = nil
    finished = false
    s.post do
      begin
        s.prompt "name: "
      rescue ex
        raised = ex
      end
      finished = true
    end
    wait_until { finished }
    raised.nil?.should be_false
  ensure
    s.try &.destroy
  end

  it "return at once on a destroyed window" do
    s = headless_screen(40, 10)
    s.destroy
    s.prompt("name: ").nil?.should be_true
    s.ask("sure?").should be_false
  end
end

describe "inline Window#leave" do
  it "scrolls a row in for the shell prompt when the region ends on the terminal's last row" do
    inline = Crysterm::Window.new(
      input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
      width: 40, height: 6, alternate: false, default_quit_keys: false)
    term_h = inline.tput.screen.height
    inline.render_row_offset = term_h - 6
    outbuf = inline.output.as(IO::Memory)
    outbuf.clear

    inline.leave

    # Cursor to the last row, then a newline from there: the region moves up
    # one row and the cursor is left on a fresh line below it.
    outbuf.to_s.should contain "\e[#{term_h};1H\n"
  ensure
    inline.try &.destroy
  end
end
