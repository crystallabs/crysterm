require "./spec_helper"

include Crysterm

# `Widget::Effect::SineScroller` scroll + wave logic, driven headlessly over
# in-memory IOs. Glyphs are painted into the screen cell buffer in `#paint`
# (`#step` only advances the frame clock), so these specs run a real
# synchronous `Window#repaint` and inspect the resulting cells. `#paint` reads
# `@frame`, so frame 0 is the state before the first `#step`.

# The row index (within the scroller) that carries glyph *ch*, or nil if none.
private def glyph_row(screen, ch, w, h)
  (0...h).find do |y|
    (0...w).any? { |x| cell_char(screen, x, y) == ch }
  end
end

describe Crysterm::Widget::Effect::SineScroller do
  it "places a glyph on the row given by the sine wave" do
    s = headless_screen(default_quit_keys: true)
    # height 5 -> amp 2; flat wave (freq 0) so every column lands on the same row.
    sc = Crysterm::Widget::Effect::SineScroller.new parent: s, top: 0, left: 0,
      width: 1, height: 5, text: "X", rainbow: false,
      wave_frequency: 0.0, wave_speed: Math::PI / 2

    # f=0: sin(0)=0 -> row amp*(1+0)=2 (render before the first step)
    s.repaint
    glyph_row(s, 'X', 1, 5).should eq 2
    # f=1: sin(pi/2)=1 -> row amp*(1+1)=4 (bottom)
    sc.step
    s.repaint
    glyph_row(s, 'X', 1, 5).should eq 4
    # f=2: sin(pi)=0   -> back to row 2
    sc.step
    s.repaint
    glyph_row(s, 'X', 1, 5).should eq 2
  end

  it "scrolls horizontally like a marquee when flat (height 1)" do
    s = headless_screen(default_quit_keys: true)
    sc = Crysterm::Widget::Effect::SineScroller.new parent: s, top: 0, left: 0,
      width: 5, height: 1, text: "ABCDE", rainbow: false

    s.repaint # f=0
    String.build { |io| (0...5).each { |x| io << cell_char(s, x, 0) } }.should eq "ABCDE"
    sc.step
    s.repaint # f=1: shifted left by one column
    String.build { |io| (0...5).each { |x| io << cell_char(s, x, 0) } }.should eq "BCDEA"
  end

  it "tints glyphs and leaves spaces blank under rainbow" do
    s = headless_screen(default_quit_keys: true)
    # "A B": columns 0 and 2 carry glyphs, column 1 is a space (blank).
    Crysterm::Widget::Effect::SineScroller.new parent: s, top: 0, left: 0,
      width: 4, height: 3, text: "A B", rainbow: true,
      wave_frequency: 0.0, wave_speed: 0.0 # flat: all glyphs on the middle row (amp=1)
    s.repaint

    row = glyph_row(s, 'A', 4, 3).not_nil!
    # The 'A' glyph carries a real (non-default) color from the rainbow path.
    cell_fg(s, 0, row).should_not eq(-1)
    cell_char(s, 0, row).should eq 'A'
    # The space between glyphs stays blank.
    cell_char(s, 1, row).should eq ' '
  end

  it "rebuilds its glyph cache (and indexes correctly) when text is reassigned" do
    s = headless_screen(default_quit_keys: true)
    # height 1 -> amp 0, flat wave: every glyph lands on row 0, so the row reads
    # the message straight across (idx == x at frame 0).
    sc = Crysterm::Widget::Effect::SineScroller.new parent: s, top: 0, left: 0,
      width: 3, height: 1, text: "ABC", rainbow: false,
      wave_frequency: 0.0, wave_speed: 0.0
    s.repaint
    String.build { |io| (0...3).each { |x| io << cell_char(s, x, 0) } }.should eq "ABC"

    # Reassigning `text` must rebuild the per-column glyph cache. A non-ASCII
    # message also exercises multibyte indexing (the reason the cache exists:
    # `String#[]` is O(n) per column for such strings). These glyphs are
    # single-width, so a width-3 scroller shows all three straight across.
    sc.text = "áéí"
    s.repaint
    String.build { |io| (0...3).each { |x| io << cell_char(s, x, 0) } }.should eq "áéí"
  end

  it "renders an all-blank frame for an all-space message" do
    s = headless_screen(default_quit_keys: true)
    Crysterm::Widget::Effect::SineScroller.new parent: s, top: 0, left: 0,
      width: 4, height: 3, text: "    ", rainbow: true
    s.repaint

    (0...3).each do |y|
      (0...4).each do |x|
        cell_char(s, x, y).should eq ' '
        cell_fg(s, x, y).should eq(-1) # default fg: nothing tinted
      end
    end
  end
end
