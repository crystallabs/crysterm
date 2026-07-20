require "./spec_helper"

include Crysterm

private def autogrow_window(max_height : Int32? = nil)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 40, alternate: false, auto_grow: true, max_height: max_height,
    default_quit_keys: false)
end

describe "inline auto_grow" do
  it "starts one row tall and pins the height" do
    win = autogrow_window
    win.auto_grow?.should be_true
    win.aheight.should eq 1
    win.screen.explicit_height?.should be_true
  end

  it "grows the region to fit content on render" do
    win = autogrow_window
    Crysterm::Widget::Box.new parent: win, top: 0, left: 0, width: 40, height: 3,
      content: "a\nb\nc"
    win.repaint
    win.content_height.should eq 3
    win.aheight.should eq 3
  end

  it "grows further as content grows" do
    win = autogrow_window
    box = Crysterm::Widget::Box.new parent: win, top: 0, left: 0, width: 40, height: 2
    win.repaint
    win.aheight.should eq 2

    box.height = 5
    win.repaint
    win.aheight.should eq 5
  end

  it "shrinks and erases the rows it vacates" do
    win = autogrow_window
    box = Crysterm::Widget::Box.new parent: win, top: 0, left: 0, width: 40, height: 6
    win.repaint
    win.aheight.should eq 6

    win.output.as(IO::Memory).clear
    box.height = 2
    win.repaint

    win.aheight.should eq 2
    out = win.output.as(IO::Memory).to_s
    # The vacated physical rows (2..5, offset 0) are cleared with EL.
    out.should contain "\e[2K"
  end

  it "respects max_height" do
    win = autogrow_window(max_height: 4)
    Crysterm::Widget::Box.new parent: win, top: 0, left: 0, width: 40, height: 20
    win.repaint
    win.aheight.should eq 4
  end

  it "scrolls the terminal up and re-anchors when growth hits the bottom" do
    win = autogrow_window
    term_h = win.tput.screen.height
    # Anchor near the bottom so the content can't fit without scrolling.
    win.render_row_offset = term_h - 3
    Crysterm::Widget::Box.new parent: win, top: 0, left: 0, width: 40, height: 6, content: "x"

    win.output.as(IO::Memory).clear
    win.repaint

    win.aheight.should eq 6
    # Re-anchored up so offset + height == the screen bottom (fits exactly).
    win.render_row_offset.should eq term_h - 6
    (win.render_row_offset + win.aheight).should eq term_h
  end

  it "does not auto-grow a full-screen window" do
    win = Crysterm::Window.new(
      input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
      width: 40, height: 10, default_quit_keys: false)
    win.auto_grow?.should be_false
    Crysterm::Widget::Box.new parent: win, top: 0, left: 0, width: 40, height: 3
    win.repaint
    win.aheight.should eq 10 # unchanged
  end
end
