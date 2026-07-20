require "./spec_helper"

include Crysterm

# Frame rendering in `Widget::TextEdit` (TEXTEDIT.md follow-up): bordered
# child frames draw a box — top/bottom border rows (positionless, like block
# margins), side bars every content row — with the text inset by the frame's
# border/margin, and the shared caret/mouse geometry staying exact through
# the per-row offsets.

private def te_screen(width = 20, height = 8)
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: width,
    height: height)
end

private def new_te(s, content = "", width = 20, height = 8)
  te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: width, height: height, content: content
  s.repaint
  te
end

private def ctl(k : ::Tput::Key)
  Crysterm::Event::KeyPress.new '\0', k
end

private def row_text(s, y, len)
  String.build do |io|
    len.times { |x| io << s.lines[y][x].char }
  end
end

describe Widget::TextEdit do
  describe "frame rendering" do
    it "draws a box around a bordered frame's blocks" do
      s = te_screen
      te = new_te s, "before\ninside\nafter"
      c = te.text_cursor
      c.set_position(7)
      c.insert_frame(TextFrameFormat.new(border: true))
      s.repaint
      row_text(s, 0, 6).should eq "before"
      row_text(s, 1, 20).should eq "┌" + "─" * 18 + "┐"
      row_text(s, 2, 8).should eq "│ inside"
      s.lines[2][19].char.should eq '│'
      row_text(s, 3, 20).should eq "└" + "─" * 18 + "┘"
      row_text(s, 4, 5).should eq "after"
    end

    it "indents by margin without bars for a borderless frame" do
      s = te_screen
      te = new_te s, "plain"
      te.text_cursor.insert_frame(TextFrameFormat.new(margin: 3))
      s.repaint
      row_text(s, 0, 8).should eq "   plain"
      te._clines.size.should eq 1 # no border rows
    end

    it "nests boxes for nested frames" do
      s = te_screen
      te = new_te s, "deep"
      c = te.text_cursor
      c.insert_frame(TextFrameFormat.new(border: true))
      c.insert_frame(TextFrameFormat.new(border: true))
      s.repaint
      row_text(s, 0, 20).should eq "┌" + "─" * 18 + "┐"
      row_text(s, 1, 20).should eq "│ ┌" + "─" * 14 + "┐ │"
      row_text(s, 2, 8).should eq "│ │ deep"
      s.lines[2][17].char.should eq '│'
      s.lines[2][19].char.should eq '│'
      row_text(s, 3, 4).should eq "│ └─"
      row_text(s, 4, 2).should eq "└─"
    end

    it "keeps mouse mapping exact past the frame inset" do
      s = te_screen
      te = new_te s, "before\ninside\nafter"
      c = te.text_cursor
      c.set_position(7)
      c.insert_frame(TextFrameFormat.new(border: true))
      s.repaint
      # Row 2 is the frame's text row; its text starts at column 2.
      te.position_at(2, 2).should eq 7
      te.position_at(3, 2).should eq 8
      # Clicking the bar maps to the line start.
      te.position_at(0, 2).should eq 7
    end

    it "steps the caret over border rows on Down/Up" do
      s = te_screen
      te = new_te s, "before\ninside\nafter"
      c = te.text_cursor
      c.set_position(7)
      c.insert_frame(TextFrameFormat.new(border: true))
      s.repaint
      te.cursor_pos = 0
      te._listener ctl(::Tput::Key::Down)
      te.cursor_pos.should eq 7 # over the top border row into "inside"
      te._listener ctl(::Tput::Key::Down)
      te.cursor_pos.should eq 14 # over the bottom border row into "after"
      te._listener ctl(::Tput::Key::Up)
      te.cursor_pos.should eq 7
    end

    it "wraps frame text within the reduced width" do
      s = te_screen
      te = new_te s, "aaaa bbbb cccc dddd"
      te.text_cursor.insert_frame(TextFrameFormat.new(border: true))
      s.repaint
      # Text rows all carry both bars.
      (1...te._clines.size - 1).each do |rl|
        s.lines[rl][0].char.should eq '│'
        s.lines[rl][19].char.should eq '│'
      end
    end
  end
end
