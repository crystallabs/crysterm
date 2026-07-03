require "./spec_helper"

include Crysterm

# Unit spec for `Overlay.place` (FORMAL-WIDGETS Part A / Piece 3): the pure
# fit-based auto-placement geometry. All coordinates absolute; no widgets
# involved, so this pins the geometry in isolation from the adoption sites.
#
# Convention for these cases: `anchor` is `{x, y, w, h}`, `size` is `{w, h}`,
# `bounds` is `{x, y, w, h}`. A "fits" case returns the raw candidate; a "no
# candidate fits" case falls back to the roomiest and clamps.

alias Side = Overlay::Side

describe Overlay do
  describe ".place" do
    # A generous 100x40 bounds so preferred sides fit unless a case shrinks it.
    bounds = {0, 0, 100, 40}

    context "preferred side fits" do
      it "places Below when there is room below" do
        # anchor at (10,5) size 8x2; popup 8x6 → below top-left (10, 7)
        Overlay.place({10, 5, 8, 2}, {8, 6}, bounds, [Side::Below]).should eq({10, 7})
      end

      it "places Right when there is room" do
        Overlay.place({10, 5, 8, 2}, {6, 4}, bounds, [Side::Right]).should eq({18, 5})
      end

      it "places at an explicit point for Side::At" do
        Overlay.place({0, 0, 0, 0}, {5, 5}, bounds, [Side::At], point: {30, 12}).should eq({30, 12})
      end

      it "returns the FIRST preferred side that fits, not a later one" do
        # Both Below and Above fit here; Below is preferred → wins.
        Overlay.place({10, 15, 8, 2}, {6, 4}, bounds, [Side::Below, Side::Above]).should eq({10, 17})
      end
    end

    context "preferred side overflows → flips to the next that fits" do
      it "flips Above when Below would run off the bottom" do
        # bounds height 20; anchor near bottom at y=16 h=2 (below starts at 18),
        # popup height 6 → below would end at 24 > 20; above starts at 16-6=10, fits.
        Overlay.place({10, 16, 8, 2}, {8, 6}, {0, 0, 100, 20}, [Side::Below, Side::Above]).should eq({10, 10})
      end

      it "flips Left when Right would run off the right edge" do
        # bounds width 30; anchor x=24 w=4 → right starts at 28, popup w=6 ends 34 > 30.
        # left starts at 24-6=18, fits.
        Overlay.place({24, 5, 4, 2}, {6, 4}, {0, 0, 30, 40}, [Side::Right, Side::Left]).should eq({18, 5})
      end
    end

    context "no candidate fits → roomiest, then clamp into bounds" do
      it "clamps a Below-only popup that runs off the bottom" do
        # bounds height 20; only Below offered; below starts at 18, popup h=6 ends 24.
        # No flip available → clamp y to 20-6=14. x already fits.
        Overlay.place({10, 16, 8, 2}, {8, 6}, {0, 0, 100, 20}, [Side::Below]).should eq({10, 14})
      end

      it "clamps horizontally too (below overflows the right edge)" do
        # anchor x=96 in a 100-wide bounds; popup w=8 → right edge 104 > 100.
        # Below fits vertically, but x clamps to 100-8=92.
        Overlay.place({96, 5, 4, 2}, {8, 6}, bounds, [Side::Below]).should eq({92, 7})
      end

      it "picks the candidate with the most visible area when neither fully fits" do
        # Tight bounds 12 tall. anchor y=6 h=2. Below starts 8 (popup h=8 ends 16,
        # overflow 4). Above starts 6-8=-2 (overflow 2 off the top). Above keeps
        # more visible → chosen, then clamped to y=0.
        Overlay.place({4, 6, 8, 2}, {8, 8}, {0, 0, 100, 12}, [Side::Below, Side::Above]).should eq({4, 0})
      end

      it "pins to the bounds origin when the popup is larger than bounds" do
        # popup 8 wide in a 5-wide bounds → cannot fit; pin x to bounds origin (0).
        Overlay.place({2, 2, 3, 2}, {8, 4}, {0, 0, 5, 40}, [Side::Below]).should eq({0, 4})
      end
    end

    context "non-zero bounds origin (padded/bordered window)" do
      it "respects a bounds that does not start at (0,0)" do
        # bounds origin (2,1): a Below popup at anchor (5,3) h=2 → (5, 5); fits.
        Overlay.place({5, 3, 8, 2}, {8, 4}, {2, 1, 20, 20}, [Side::Below]).should eq({5, 5})
      end

      it "clamps against the shifted bounds' far edge, not the screen" do
        # bounds {2,1,20,20} → right edge = 22. anchor x=18, popup w=8 ends 26 > 22.
        # clamp x to 22-8=14.
        Overlay.place({18, 3, 2, 2}, {8, 4}, {2, 1, 20, 20}, [Side::Below]).should eq({14, 5})
      end
    end

    context "degenerate inputs" do
      it "treats an empty prefer list as [Below]" do
        Overlay.place({10, 5, 8, 2}, {6, 4}, bounds, [] of Side).should eq({10, 7})
      end
    end
  end
end
