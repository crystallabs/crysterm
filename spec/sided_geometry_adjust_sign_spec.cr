require "./spec_helper"

# Locks the sign semantics of `SidedGeometry#adjust`, documented (incorrectly,
# before the fix) as "Grows (sign = 1) or shrinks (sign = -1)". The actual
# behavior — relied on by every call site in `widget_rendering.cr`, and by that
# file's own comment ("`adjust(pos)` shrinks in place") — is the opposite:
#   * sign = 1 (the default) INSETS: moves each edge inward, SHRINKING the rect.
#   * sign = -1 OUTSETS: moves each edge outward, GROWING the rect.
# This guards against a "fix" that flips the sign to match the old wrong comment.
module Crysterm
  # Minimal position object exposing the xi/xl/yi/yl the mutating overload writes.
  private class AdjustPos
    property xi : Int32
    property xl : Int32
    property yi : Int32
    property yl : Int32

    def initialize(@xi, @xl, @yi, @yl)
    end
  end

  describe SidedGeometry do
    describe "#adjust" do
      it "sign = 1 (default) insets — shrinks the rectangle inward" do
        border = Border.new(1, 1, 1, 1)              # left/top/right/bottom = 1
        xi, xl, yi, yl = border.adjust(0, 10, 0, 10) # default sign = 1
        {xi, xl, yi, yl}.should eq({1, 9, 1, 9})
        (xl - xi).should eq 8 # width 10 -> 8: shrank
        (yl - yi).should eq 8
      end

      it "sign = -1 outsets — grows the rectangle outward" do
        border = Border.new(1, 1, 1, 1)
        xi, xl, yi, yl = border.adjust(0, 10, 0, 10, -1)
        {xi, xl, yi, yl}.should eq({-1, 11, -1, 11})
        (xl - xi).should eq 12 # width 10 -> 12: grew
        (yl - yi).should eq 12
      end

      it "the mutating overload insets in place with the default sign" do
        border = Border.new(2, 3, 2, 3) # left=2 top=3 right=2 bottom=3
        pos = AdjustPos.new(0, 20, 0, 20)
        border.adjust(pos)
        pos.xi.should eq 2               # left inward
        pos.xl.should eq 18              # right inward
        pos.yi.should eq 3               # top inward
        pos.yl.should eq 17              # bottom inward
        (pos.xl - pos.xi).should be < 20 # shrank, not grew
      end
    end
  end
end
