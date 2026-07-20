require "./spec_helper"

include Crysterm

# `Widget::Marquee` scroll logic, driven headlessly over in-memory IOs. Glyphs
# are painted straight into the screen cell buffer in `#render` (`#step` only
# advances the frame clock), so these specs run a real synchronous
# `Window#repaint` and inspect the resulting cells. `#render` reads `@frame`, so
# frame 0 is the state before the first `#step`.

private def marquee_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new)
end

private def cell_char(screen, y, x)
  screen.lines[y][x].char
end

private def cell_fg(screen, y, x)
  Crysterm::Attr.unpack_color(Crysterm::Attr.fg(screen.lines[y][x].attr))
end

# Top content row, rendered, as a String.
private def row0(screen, w)
  String.build { |io| (0...w).each { |x| io << cell_char(screen, 0, x) } }
end

describe Crysterm::Widget::Marquee do
  it "renders an awidth-wide window onto the looping message" do
    s = marquee_screen
    m = Crysterm::Widget::Marquee.new parent: s, top: 0, left: 0, width: 10, height: 1, text: "ABCDE"
    w = m.awidth

    s.repaint # frame 0
    row0(s, w).should eq String.build { |io| (0...w).each { |x| io << "ABCDE"[x % 5] } }
  end

  it "scrolls right-to-left: one column per step" do
    s = marquee_screen
    m = Crysterm::Widget::Marquee.new parent: s, top: 0, left: 0, width: 10, height: 1, text: "ABCDE"
    w = m.awidth

    m.step # frame 1: window shifted left by one column
    s.repaint
    row0(s, w).should eq String.build { |io| (0...w).each { |x| io << "ABCDE"[(1 + x) % 5] } }
  end

  it "scrolls left-to-right in :right direction" do
    s = marquee_screen
    m = Crysterm::Widget::Marquee.new parent: s, top: 0, left: 0, width: 10, height: 1,
      text: "ABCDE", direction: :right
    w = m.awidth

    # Frame 0: column x shows text[x] — the message reads normally (not mirrored).
    s.repaint
    row0(s, w).should eq String.build { |io| (0...w).each { |x| io << "ABCDE"[x % 5] } }

    # After one step the window slides *right*: column x now shows text[x-1]
    # (sign-safe modulo), i.e. the whole string moves one column to the right.
    m.step
    s.repaint
    row0(s, w).should eq String.build { |io| (0...w).each { |x| io << "ABCDE"[((x - 1) % 5)] } }
  end

  it "loops seamlessly through trailing-space gaps" do
    s = marquee_screen
    m = Crysterm::Widget::Marquee.new parent: s, top: 0, left: 0, width: 4, height: 1, text: "AB  "
    w = m.awidth

    s.repaint # frame 0
    first = row0(s, w)
    # Over text.size steps, the window returns to its starting frame.
    m.text.size.times { m.step }
    s.repaint
    row0(s, w).should eq first
    w.should be > 0
  end

  it "tints each non-space glyph when rainbow is on" do
    s = marquee_screen
    Crysterm::Widget::Marquee.new parent: s, top: 0, left: 0, width: 6, height: 1,
      text: "AB", rainbow: true
    s.repaint # frame 0: A B A B A B, all tinted
    cell_char(s, 0, 0).should eq 'A'
    cell_char(s, 0, 1).should eq 'B'
    cell_fg(s, 0, 0).should_not eq(-1)
    cell_fg(s, 0, 1).should_not eq(-1)
  end

  it "leaves spaces untinted under rainbow" do
    s = marquee_screen
    Crysterm::Widget::Marquee.new parent: s, top: 0, left: 0, width: 4, height: 1,
      text: "    ", rainbow: true
    s.repaint
    (0...4).each do |x|
      cell_char(s, 0, x).should eq ' '
      cell_fg(s, 0, x).should eq(-1) # spaces untinted
    end
  end
end
