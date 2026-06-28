require "./spec_helper"

# Focused specs for the `Widget::Media::Glyph::OCTANT` table: the mask -> glyph
# mapping for the 2x4 sub-cell ("octant") render mode.
#
# A 2x4 cell encodes 8 sub-cells as a byte. The bit layout (see `paint_two_color`)
# is LSB = top-left, then row-major:
#     pos1=1   pos2=2
#     pos3=4   pos4=8
#     pos5=16  pos6=32
#     pos7=64  pos8=128
# so the mask for Unicode "BLOCK OCTANT-<positions>" is the sum of `1 << (N-1)`.
#
# 230 of the 256 patterns are the Block Octants U+1CD00..U+1CDE5 (Unicode 16.0,
# "Symbols for Legacy Computing Supplement"), assigned in increasing mask order
# while skipping the 26 patterns that already exist as other block characters.
# These assertions are checked against the authoritative UCD NamesList.

private OCTANT = Crysterm::Widget::Media::Glyph::OCTANT

# Mask from a list of filled Unicode octant positions (1..8).
private def mask(*pos : Int32) : Int32
  pos.reduce(0) { |m, p| m | (1 << (p - 1)) }
end

describe Crysterm::Widget::Media::Glyph do
  describe "OCTANT table" do
    it "covers exactly the 256 patterns" do
      OCTANT.size.should eq 256
    end

    it "maps the special-cased patterns to pre-existing block characters" do
      OCTANT[0].should eq ' '                        # empty -> SPACE
      OCTANT[mask(1, 2, 3, 4, 5, 6, 7, 8)].should eq '█' # full -> FULL BLOCK
      OCTANT[mask(1, 2, 3, 4)].should eq '▀'         # top half -> UPPER HALF BLOCK
      OCTANT[mask(5, 6, 7, 8)].should eq '▄'         # bottom half -> LOWER HALF BLOCK
      OCTANT[mask(1, 3, 5, 7)].should eq '▌'         # left col -> LEFT HALF BLOCK
      OCTANT[mask(2, 4, 6, 8)].should eq '▐'         # right col -> RIGHT HALF BLOCK
    end

    it "maps the quadrant-aligned patterns to QUADRANT characters" do
      OCTANT[mask(1, 3)].should eq '▘'      # QUADRANT UPPER LEFT
      OCTANT[mask(2, 4)].should eq '▝'      # QUADRANT UPPER RIGHT
      OCTANT[mask(5, 7)].should eq '▖'      # QUADRANT LOWER LEFT
      OCTANT[mask(6, 8)].should eq '▗'      # QUADRANT LOWER RIGHT
      OCTANT[mask(2, 4, 5, 7)].should eq '▞' # UPPER RIGHT AND LOWER LEFT
      OCTANT[mask(1, 3, 6, 8)].should eq '▚' # UPPER LEFT AND LOWER RIGHT
    end

    it "maps the quarter/three-quarter patterns to their dedicated characters" do
      OCTANT[mask(1, 2)].should eq '\u{1FB82}'          # UPPER ONE QUARTER BLOCK
      OCTANT[mask(7, 8)].should eq '\u{2582}'           # LOWER ONE QUARTER BLOCK
      OCTANT[mask(1, 2, 3, 4, 5, 6)].should eq '\u{1FB85}' # UPPER THREE QUARTERS BLOCK
      OCTANT[mask(3, 4, 5, 6, 7, 8)].should eq '\u{2586}'  # LOWER THREE QUARTERS BLOCK
      OCTANT[mask(3, 5)].should eq '\u{1FBE6}'          # MIDDLE LEFT ONE QUARTER BLOCK
      OCTANT[mask(4, 6)].should eq '\u{1FBE7}'          # MIDDLE RIGHT ONE QUARTER BLOCK
    end

    it "maps single-cell patterns to the half-of-quarter blocks" do
      OCTANT[mask(1)].should eq '\u{1CEA8}'  # LEFT HALF UPPER ONE QUARTER BLOCK
      OCTANT[mask(2)].should eq '\u{1CEAB}'  # RIGHT HALF UPPER ONE QUARTER BLOCK
      OCTANT[mask(7)].should eq '\u{1CEA3}'  # LEFT HALF LOWER ONE QUARTER BLOCK
      OCTANT[mask(8)].should eq '\u{1CEA0}'  # RIGHT HALF LOWER ONE QUARTER BLOCK
    end

    it "maps the irregular Block Octants in their true Unicode order" do
      # U+1CD00 is BLOCK OCTANT-3 (mask 4), NOT octant-1 -- the ordering is not
      # a naive sequential mask layout.
      OCTANT[mask(3)].should eq '\u{1CD00}'                # BLOCK OCTANT-3
      OCTANT[mask(2, 3)].should eq '\u{1CD01}'             # BLOCK OCTANT-23
      OCTANT[mask(1, 2, 3)].should eq '\u{1CD02}'          # BLOCK OCTANT-123
      OCTANT[mask(4)].should eq '\u{1CD03}'                # BLOCK OCTANT-4
      OCTANT[mask(1, 2, 4, 5)].should eq '\u{1CD13}'       # BLOCK OCTANT-1245
      OCTANT[mask(1, 2, 7, 8)].should eq '\u{1CDAE}'       # BLOCK OCTANT-1278
      # Last codepoint in the block is BLOCK OCTANT-2345678 (mask 254).
      OCTANT[mask(2, 3, 4, 5, 6, 7, 8)].should eq '\u{1CDE5}'
    end

    it "never assigns a codepoint past the end of the Block Octant range" do
      # The old table walked U+1CD00 sequentially for 250 masks, overrunning the
      # 230-codepoint block (ending U+1CDE5) into unrelated symbols. No glyph may
      # land in U+1CDE6..U+1CDFF.
      OCTANT.count { |c| (0x1CDE6..0x1CDFF).includes?(c.ord) }.should eq 0
    end
  end
end
