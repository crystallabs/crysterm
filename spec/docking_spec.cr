require "./spec_helper"

include Crysterm

# Behavior lock for `Docking.angle_at`, the box-drawing junction resolver. It was
# refactored from four hand-written per-direction blocks into a single
# `neighbor_angle` helper driven by a tuple of deltas; these cases pin the
# resulting joining character (and the contrast handling) so that refactor — and
# any future one — is provably behavior-preserving.

# Builds an `Array(Row)` grid from rows of text, one cell per character, all with
# attribute `attr` unless overridden afterwards.
private def grid(rows : Array(String), attr : Int64 = 0_i64) : Array(Crysterm::Screen::Row)
  rows.map do |s|
    row = Crysterm::Screen::Row.new
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
    # The cell at column 0 is a horizontal rule; the LAST column is also a rule.
    # Array `[]?` treats index -1 as "from the end", so without the explicit
    # `>= 0` guard the left lookup would wrap to that last column and add a
    # spurious left segment. With the guard there is no left neighbor (nor up,
    # right, or down here), so the isolated rule resolves to a blank.
    Docking.angle_at(grid(["─ ─"]), 0, 0, DockContrast::Ignore).should eq ' '
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
  end
end
