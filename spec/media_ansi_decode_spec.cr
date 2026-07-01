require "./spec_helper"

# Focused specs for `Crysterm::Widget::Media.decode_ansi`'s self-contained ANSI
# interpreter. The output is a still `PNGGIF::PNG`; we assert on its pixel
# dimensions (`cols*cw` x `rows*ch`, i.e. the interpreter's cell grid size).
# Two inputs resolving to the same visible grid must produce the same
# dimensions.

private def png(s : String)
  Crysterm::Widget::Media.decode_ansi(s.to_slice)
end

describe Crysterm::Widget::Media do
  describe ".decode_ansi CSI parsing" do
    it "consumes private-marker sequences instead of rendering their bytes" do
      # `ESC[?7h` (autowrap on) must be swallowed, leaving only the single 'X'.
      with_marker = png("\e[?7hX")
      plain = png("X")
      with_marker.width.should eq plain.width
      with_marker.height.should eq plain.height
    end

    it "consumes a hide-cursor private sequence" do
      png("\e[?25lX").width.should eq png("X").width
    end

    it "consumes intermediate bytes before the final byte" do
      # DECSCUSR `ESC[1 q` has an intermediate space (0x20) before final 'q'.
      png("\e[1 qX").width.should eq png("X").width
    end

    it "still honours ordinary SGR + a printed glyph" do
      png("\e[31mX").width.should eq png("X").width
    end

    it "still honours cursor positioning (CUP)" do
      # `ESC[1;3H` moves to column 3 (1-based) before printing, so the grid is
      # 3 columns wide — wider than a single bare glyph.
      png("\e[1;3HX").width.should be > png("X").width
    end

    it "treats a parameterless relative move (CUF) as a move of 1" do
      # `X ESC[C Y`: print X at col 0, CUF (no param) advances 1 to col 2, print
      # Y → 3-column grid. Must match an explicit `ESC[1C` exactly.
      png("X\e[CY").width.should eq png("X\e[1CY").width
      png("X\e[CY").width.should be > png("XY").width
    end
  end

  describe ".decode_ansi SGR background" do
    # A space cell has no glyph ink, so its pixels are painted purely with the
    # resolved background color, letting us assert the exact RGB.
    it "selects a bright background via aixterm 100..107" do
      px = png("\e[101m ").bmp[0][0] # bright red = ANSI index 9 (0xFF5555)
      {px.r, px.g, px.b}.should eq({0xFF, 0x55, 0x55})
    end

    it "clears the bright-background flag when a normal background follows" do
      # `ESC[101m` selects bright-red bg; `ESC[41m` after must drop to *normal*
      # red (index 1, 0xAA0000), not stay bright (index 9, 0xFF5555).
      px = png("\e[101m\e[41m ").bmp[0][0]
      {px.r, px.g, px.b}.should eq({0xAA, 0x00, 0x00})
    end

    it "clears the bright-background flag when the default background follows" do
      # `ESC[101m` then `ESC[49m` (default bg) must render as the default
      # background (index 0, black), not a bright color.
      px = png("\e[101m\e[49m ").bmp[0][0]
      {px.r, px.g, px.b}.should eq({0x00, 0x00, 0x00})
    end
  end

  describe ".decode_ansi reverse video (SGR 7 / 27)" do
    # A space cell renders purely its background colour, so reversing it
    # surfaces the *foreground* — letting us assert the swap on the exact RGB.
    it "swaps default fg/bg so a reversed blank shows the foreground (white)" do
      # Default fg is white (index 7, 0xAAAAAA); reversed, the blank's
      # background becomes that white instead of the default black.
      px = png("\e[7m ").bmp[0][0]
      {px.r, px.g, px.b}.should eq({0xAA, 0xAA, 0xAA})
    end

    it "swaps explicit fg/bg under reverse video" do
      # fg red (31), bg white (47); reversed, the blank's background is the red fg.
      px = png("\e[31;47m\e[7m ").bmp[0][0]
      {px.r, px.g, px.b}.should eq({0xAA, 0x00, 0x00})
    end

    it "restores normal video with SGR 27" do
      # Reverse on then off: the blank renders the default black background again.
      px = png("\e[7m\e[27m ").bmp[0][0]
      {px.r, px.g, px.b}.should eq({0x00, 0x00, 0x00})
    end

    it "clears reverse on a full SGR reset (SGR 0)" do
      px = png("\e[7m\e[0m ").bmp[0][0]
      {px.r, px.g, px.b}.should eq({0x00, 0x00, 0x00})
    end
  end

  describe ".decode_ansi extended-colour SGR" do
    # `38`/`48` extended-colour selectors must be consumed (and mapped to the
    # nearest 16-colour entry) rather than letting their sub-parameters fall
    # through and be misread as standalone SGR codes.
    it "maps a 256-colour background (48;5;n) to the palette" do
      # Index 9 is bright red (0xFF5555) in both the 256- and 16-colour palettes.
      px = png("\e[48;5;9m ").bmp[0][0]
      {px.r, px.g, px.b}.should eq({0xFF, 0x55, 0x55})
    end

    it "maps a truecolour background (48;2;r;g;b) to the nearest palette entry" do
      # Pure red maps to normal red (index 1, 0xAA0000). The `0` green/blue
      # channels must NOT be misread as SGR 0 (reset all) — the old
      # fall-through did this, leaving the bg at default black.
      px = png("\e[48;2;255;0;0m ").bmp[0][0]
      {px.r, px.g, px.b}.should eq({0xAA, 0x00, 0x00})
    end

    it "does not let an extended selector's params corrupt a following SGR" do
      # `48;5;0` (256-colour black bg) then `41` (normal red bg). A `5` leaking
      # as blink or the index being mis-consumed would desync the parse. Result
      # must be the plain normal-red background (index 1, 0xAA0000).
      px = png("\e[48;5;0m\e[41m ").bmp[0][0]
      {px.r, px.g, px.b}.should eq({0xAA, 0x00, 0x00})
    end
  end
end
