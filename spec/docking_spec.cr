require "./spec_helper"

include Crysterm

# Behavior lock for `Docking.angle_at`, the box-drawing junction resolver. Pins
# the resulting joining character (and contrast handling) so refactors of
# `neighbor_angle` stay behavior-preserving.

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
    # Top-left corner: right + down neighbors only.
    Docking.angle_at(grid(["┌─", "│ "]), 0, 0, DockContrast::Ignore).should eq '┌'
    # T pointing down: left + right + down.
    Docking.angle_at(grid(["─┬─", " │ "]), 1, 0, DockContrast::Ignore).should eq '┬'
    # Horizontal run: left + right.
    Docking.angle_at(grid(["───"]), 1, 0, DockContrast::Ignore).should eq '─'
  end

  it "does not wrap to the far edge for an off-grid left/up neighbor" do
    # Centre `┐` at (0,0) has only a DOWN neighbor; last column is a rule (`─`).
    # `Array#[]?` treats index -1 as "from the end", so without the explicit
    # `>= 0` guard the left lookup would wrap to that rule, turning down-only
    # `0001` (`│`) into `1001` (`┐`). With the guard it stays `│`.
    Docking.angle_at(grid(["┐ ─", "│  "]), 0, 0, DockContrast::Ignore).should eq '│'
  end

  it "preserves an isolated line glyph (no line neighbors) instead of erasing it" do
    # All-blank neighbors yield angle `0000`, which has no `ANGLE_TABLE` entry, so
    # `angle_at` returns the cell's original character (matching blessed's
    # empty-string `'0000'` entry) instead of blanking it to a space.
    Docking.angle_at(grid(["─"]), 0, 0, DockContrast::Ignore).should eq '─'
    Docking.angle_at(grid([" │ "]), 1, 0, DockContrast::Ignore).should eq '│'
  end

  describe "contrast handling" do
    # A '│' that would normally dock to '┼', but the UP neighbor's attribute differs.
    contrasting = -> do
      g = grid [
        " │ ",
        "─│─",
        " │ ",
      ]
      g[0][1].attr = 99_i64 # differs from the rest (attr 0)
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
      # Only the up neighbor (attr 99) contrasts, so centre blends with it.
      g[1][1].attr.should eq Colors.blend(99_i64, 0_i64)
    end

    it "Blend mixes in *every* contrasting neighbor, not just the last one" do
      # UP and DOWN neighbors both differ from the centre (left/right match).
      # Previously each neighbor blended against the original centre attr and
      # overwrote the cell, so only the last-processed neighbor (DOWN, in
      # L/U/R/D order) survived. Accumulating into the running attr keeps both.
      g = grid [
        " │ ",
        "─┼─",
        " │ ",
      ]
      g[0][1].attr = 90_i64 # up neighbor
      g[2][1].attr = 40_i64 # down neighbor

      Docking.angle_at(g, 1, 1, DockContrast::Blend).should eq '┼'
      result = g[1][1].attr

      # Not merely the last (down) neighbor's blend — up contributed too.
      result.should_not eq Colors.blend(40_i64, 0_i64)
      # Progressive blend: up first (vs original centre 0), then down mixed in.
      result.should eq Colors.blend(40_i64, Colors.blend(90_i64, 0_i64))
    end
  end
end
