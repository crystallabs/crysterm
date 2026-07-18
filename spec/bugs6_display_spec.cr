require "./spec_helper"

include Crysterm

# Regression specs for BUGS6 "Display / Indicator Widgets".
#
#  BUG 1 (src/widget/marquee.cr, src/widget/effect/sine_scroller.cr):
#     `Direction::Right` rendered the message reversed (mirrored). The index was
#     `f - x`, which negates the spatial ordering, so column x showed a text
#     position that *decreases* as x grows — the string was drawn backwards. A
#     right-scrolling ticker needs column x to show `text[x - f]`.
#
#  BUG 2 (src/widget/markdown.cr): GFM-table column widths and cell padding used
#     the codepoint count (`String#size`) instead of terminal display width, so a
#     CJK/emoji cell (1 codepoint, 2 columns) computed its column too narrow and
#     the `─`/`┬`/`│` chrome misaligned. Now uses `Unicode.display_width`.
#
#  BUG 3 (src/widget/bigtext.cr): full-width (16-px) glyphs were truncated to
#     their left half and the pen advanced by only the half-width cell size, so a
#     wide glyph rendered its left half and the next glyph overlapped. The render
#     loop now reads each glyph's own column count.
#
#  BUG 4 (src/widget/gradient.cr): the final gradient stop was never painted at
#     the last column — `t` reached only `(W-1)/W`, never `1.0` (off by `1/W`).
#     Inclusive endpoints need the divisor `span - 1` (guarding `span == 1`).

private def bugs6_screen(w = 80, h = 24)
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: w,
    height: h,
    default_quit_keys: false)
end

private def cell_char(screen, y, x)
  screen.lines[y][x].char
end

private def cell_bg(screen, y, x)
  Crysterm::Attr.unpack_color(Crysterm::Attr.bg(screen.lines[y][x].attr))
end

private def row_str(screen, y, w)
  String.build { |io| (0...w).each { |x| c = cell_char(screen, y, x); io << (c == '\0' ? ' ' : c) } }
end

describe "BUGS6 bug 1: Marquee :right renders forwards, not mirrored" do
  it "shows text[x] across the row at frame 0 (not the reversed order)" do
    s = bugs6_screen
    Crysterm::Widget::Marquee.new parent: s, top: 0, left: 0, width: 5, height: 1,
      text: "ABCDE", direction: :right
    s._render # frame 0: column x shows text[(x - 0) % 5]
    row_str(s, 0, 5).should eq "ABCDE"
    # Guard against the old mirrored output ("AEDCB").
    row_str(s, 0, 5).should_not eq "AEDCB"
  end

  it "travels left-to-right: one column shift per step" do
    s = bugs6_screen
    m = Crysterm::Widget::Marquee.new parent: s, top: 0, left: 0, width: 5, height: 1,
      text: "ABCDE", direction: :right
    m.step # frame 1: column x shows text[(x - 1) % 5]; the window slides right
    s._render
    row_str(s, 0, 5).should eq "EABCD"
  end
end

describe "BUGS6 bug 1: SineScroller :right renders forwards, not mirrored" do
  it "reads the message straight across a flat, height-1 scroller" do
    s = bugs6_screen
    # height 1 -> amp 0, flat wave: every glyph lands on row 0.
    Crysterm::Widget::Effect::SineScroller.new parent: s, top: 0, left: 0,
      width: 5, height: 1, text: "ABCDE", direction: :right, rainbow: false,
      wave_frequency: 0.0, wave_speed: 0.0
    s._render # frame 0
    row_str(s, 0, 5).should eq "ABCDE"
    row_str(s, 0, 5).should_not eq "AEDCB"
  end
end

describe "BUGS6 bug 2: Markdown table sizes columns by display width" do
  it "draws the border wide enough for a full-width (CJK) header cell" do
    s = bugs6_screen 40, 12
    saved = Crysterm::CSS.default_stylesheet
    Crysterm::CSS.default_stylesheet = Crysterm::CSS::Stylesheet.new
    begin
      # Single-column table whose header is one full-width CJK glyph (1 codepoint,
      # 2 display columns). The pure box-drawing top border is 1 cell per char, so
      # its dash count reflects the computed column width directly:
      #   display width 2 -> "┌────┐" (w+2 = 4 dashes)
      #   codepoint  size 1 -> "┌───┐" (the old, too-narrow rendering)
      Crysterm::Widget::Markdown.new parent: s, top: 0, left: 0, width: 40, height: 12,
        markdown: "| 世 |\n|---|\n"
      s._render
      body = (0...s.aheight).map { |y| row_str(s, y, s.awidth) }.join("\n")
      body.includes?("┌────┐").should be_true # ┌────┐
      body.includes?("┌───┐").should be_false # ┌───┐ (old)
    ensure
      Crysterm::CSS.default_stylesheet = saved
    end
  end
end

describe "BUGS6 bug 3: BigText renders full-width glyphs in full" do
  it "lights pixels in the right half of a 16-px CJK glyph" do
    s = bugs6_screen 40, 20
    # foreground_char makes lit pixels observable as a visible char.
    Crysterm::Widget::BigText.new parent: s, top: 0, left: 0, width: 30, height: 16,
      content: "世", foreground_char: '#'
    s._render

    lit_cols = [] of Int32
    (0...16).each do |y|
      (0...30).each do |x|
        lit_cols << x if cell_char(s, y, x) == '#'
      end
    end
    lit_cols.should_not be_empty
    # A full-width Unifont glyph spans 16 columns; the bug clipped it to 0..7.
    lit_cols.max.should be >= 8
  end

  it "keeps a half-width glyph within its 8-px cell" do
    s = bugs6_screen 40, 20
    Crysterm::Widget::BigText.new parent: s, top: 0, left: 0, width: 30, height: 16,
      content: "A", foreground_char: '#'
    s._render

    max_col = 0
    (0...16).each do |y|
      (0...30).each do |x|
        max_col = x if cell_char(s, y, x) == '#' && x > max_col
      end
    end
    max_col.should be < 8 # half-width glyph stays in columns 0..7
  end
end

describe "BUGS6 bug 4: Gradient paints its final stop at the last column" do
  it "shows the exact end color in the last column (horizontal)" do
    s = bugs6_screen 20, 6
    # Two hard stops; with inclusive endpoints the first column is the start
    # color and the last column is the end color exactly.
    g = Crysterm::Widget::Gradient.new parent: s, top: 0, left: 0, width: 8, height: 1,
      stops: [0xff0000, 0x00ff00]
    s._render
    w = g.awidth
    xi = 0
    cell_bg(s, 0, xi).should eq 0xff0000         # first column: start stop
    cell_bg(s, 0, xi + w - 1).should eq 0x00ff00 # last column: end stop (was never reached)
  end

  it "shows the exact end color in the last row (vertical)" do
    s = bugs6_screen 20, 8
    g = Crysterm::Widget::Gradient.new parent: s, top: 0, left: 0, width: 4, height: 6,
      stops: [0xff0000, 0x00ff00], direction: :vertical
    s._render
    h = g.aheight
    cell_bg(s, 0, 0).should eq 0xff0000
    cell_bg(s, h - 1, 0).should eq 0x00ff00
  end
end
