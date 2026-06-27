require "./spec_helper"

# Focused specs for `Crysterm::Widget::Media.decode_ansi`'s self-contained ANSI
# interpreter. The output is a still `PNGGIF::PNG`; we assert on its pixel
# dimensions, which are `cols*cw` x `rows*ch` — i.e. the size of the cell grid
# the interpreter built. Two inputs that should resolve to the same visible
# grid must produce the same dimensions.

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
      # A plain coloured glyph yields exactly one cell, same grid as bare 'X'.
      png("\e[31mX").width.should eq png("X").width
    end

    it "still honours cursor positioning (CUP)" do
      # `ESC[1;3H` moves to column 3 (1-based) before printing, so the grid is
      # 3 columns wide — wider than a single bare glyph.
      png("\e[1;3HX").width.should be > png("X").width
    end

    it "treats a parameterless relative move (CUF) as a move of 1" do
      # `X ESC[C Y`: print X at col 0, CUF (no param) must advance 1 to col 2,
      # print Y → a 3-column grid. An explicit `ESC[1C` must match exactly.
      png("X\e[CY").width.should eq png("X\e[1CY").width
      png("X\e[CY").width.should be > png("XY").width
    end
  end
end
