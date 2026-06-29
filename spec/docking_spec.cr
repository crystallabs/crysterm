require "./spec_helper"

include Crysterm

# Behavior lock for `Docking.angle_at`, the box-drawing junction resolver. It was
# refactored from four hand-written per-direction blocks into a single
# `neighbor_angle` helper driven by a tuple of deltas; these cases pin the
# resulting joining character (and the contrast handling) so that refactor — and
# any future one — is provably behavior-preserving.

# Builds an `Array(Row)` grid from rows of text, one cell per character, all with
# attribute `attr` unless overridden afterwards.
private def grid(rows : Array(String), attr : Int64 = 0_i64) : Array(Crysterm::Window::Row)
  rows.map do |s|
    row = Crysterm::Window::Row.new
    s.each_char { |c| row.push attr, c }
    row
  end
end

describe "Docking.angle_at" do
  it "joins a four-way crossing into ┼" do
    g = grid [
      " │ ",
      "─┼─",
      " │ ",
    ]
    Docking.angle_at(g, 1, 1, DockContrast::Ignore).should eq '┼'
  end

  it "resolves corners and T-junctions from the present neighbors" do
    # Top-left corner: only right + down neighbors.
    Docking.angle_at(grid(["┌─", "│ "]), 0, 0, DockContrast::Ignore).should eq '┌'
    # T pointing down: left + right + down (the ┬ is on the top row).
    Docking.angle_at(grid(["─┬─", " │ "]), 1, 0, DockContrast::Ignore).should eq '┬'
    # Plain horizontal run: left + right.
    Docking.angle_at(grid(["───"]), 1, 0, DockContrast::Ignore).should eq '─'
  end

  it "does not wrap to the far edge for an off-grid left/up neighbor" do
    # The centre `┐` at (0,0) has only a DOWN neighbor (`│`); the LAST column is a
    # rule (`─`). Array `[]?` treats index -1 as "from the end", so without the
    # explicit `>= 0` guard the left lookup would wrap to that last-column rule and
    # add a spurious left segment, turning the down-only `0001` (`│`) into `1001`
    # (`┐`). With the guard there is no left neighbor, so it stays `│`.
    Docking.angle_at(grid(["┐ ─", "│  "]), 0, 0, DockContrast::Ignore).should eq '│'
  end

  it "preserves an isolated line glyph (no line neighbors) instead of erasing it" do
    # A line-drawing char whose four neighbors are all blank yields angle `0000`,
    # which has no `ANGLE_TABLE` entry, so `angle_at` returns the cell's original
    # character (matching blessed's empty-string `'0000'` entry). A one-cell rule
    # must survive a docking pass rather than being blanked to a space.
    Docking.angle_at(grid(["─"]), 0, 0, DockContrast::Ignore).should eq '─'
    Docking.angle_at(grid([" │ "]), 1, 0, DockContrast::Ignore).should eq '│'
  end

  describe "contrast handling" do
    # A '│' that, with four like neighbors, would normally dock to '┼' — but the
    # UP neighbor carries a different attribute.
    contrasting = -> do
      g = grid [
        " │ ",
        "─│─",
        " │ ",
      ]
      g[0][1].attr = 99_i64 # up neighbor differs from the rest (attr 0)
      g
    end

    it "Ignore docks regardless of differing attributes" do
      Docking.angle_at(contrasting.call, 1, 1, DockContrast::Ignore).should eq '┼'
    end

    it "DontDock leaves the original character untouched" do
      Docking.angle_at(contrasting.call, 1, 1, DockContrast::DontDock).should eq '│'
    end

    it "Blend docks and blends the cell's attribute toward the neighbor's" do
      g = contrasting.call
      Docking.angle_at(g, 1, 1, DockContrast::Blend).should eq '┼'
      # Only the up neighbor (attr 99) contrasts, so the centre blends with it.
      g[1][1].attr.should eq Colors.blend(99_i64, 0_i64)
    end

    it "Blend mixes in *every* contrasting neighbor, not just the last one" do
      # A four-way crossing whose UP and DOWN neighbors carry different attrs
      # from the centre (left/right match). Blend's intent is the smoothest
      # transition, so the centre must reflect *both* contrasting neighbors.
      # The previous code blended each neighbor against the original centre attr
      # and overwrote the cell every time, so only the last-processed contrasting
      # neighbor (DOWN, in L/U/R/D order) survived — the UP neighbor's colour was
      # silently dropped. Accumulating into the running attr keeps both.
      g = grid [
        " │ ",
        "─┼─",
        " │ ",
      ]
      g[0][1].attr = 90_i64 # up neighbor
      g[2][1].attr = 40_i64 # down neighbor

      Docking.angle_at(g, 1, 1, DockContrast::Blend).should eq '┼'
      result = g[1][1].attr

      # Not merely the last (down) neighbor's blend — the up neighbor contributed.
      result.should_not eq Colors.blend(40_i64, 0_i64)
      # It is the progressive blend of both: up first (vs the original centre 0),
      # then down mixed into that running value.
      result.should eq Colors.blend(40_i64, Colors.blend(90_i64, 0_i64))
    end
  end
end
