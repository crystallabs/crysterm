require "./spec_helper"

include Crysterm

# Regression locks for BUGS15 findings #2, #30 and #42, all in the docking path.

# Builds an `Array(Row)` grid from rows of text, one cell per character.
private def grid(rows : Array(String), attr : Int64 = 0_i64) : Array(Crysterm::Window::Row)
  rows.map do |s|
    row = Crysterm::Window::Row.new
    s.each_char { |c| row.push attr, c }
    row
  end
end

private def bugs15_dock_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 40, height: 20,
    default_quit_keys: false)
end

# #2 — `Docking.dock` resolved each stop row with `lines[y]?`, whose negative
# index counts from the END of the array. A negative stop (an off-top widget's
# unclamped `coords.yi`) therefore borrowed and corrupted a row near the bottom
# of the screen. The fix skips negative stop rows when collecting them.
describe "Docking.dock (negative stop rows, BUGS15 #2)" do
  it "does not corrupt a bottom row when a negative stop wraps to it" do
    # Row 0 holds a `┴` (has an UP arm); the last row (index -1) holds a plain
    # `─`. Without the guard, stop -1 resolves to the last row and its down
    # neighbor wraps to row 0's `┴`, rewriting the `─` to `│`.
    g = grid ["┴", "─"]
    Docking.dock(g, {-1 => true}, 1, DockContrast::Ignore)
    g[1][0].char.should eq '─'
    g[0][0].char.should eq '┴'
  end

  it "still docks a legitimate (non-negative) stop row" do
    g = grid [
      " │ ",
      "─┼─",
      " │ ",
    ]
    # Break the centre, then let a real stop repair it.
    g[1][1].char = '─'
    Docking.dock(g, {1 => true}, 3, DockContrast::Ignore)
    g[1][1].char.should eq '┼'
  end
end

# #30 — In ASCII-tier docking (`ascii: true`) `+` is a full four-arm junction.
# A plain-text `+` next to another `+`/`-`/`|` on a stop row reciprocated a
# single arm, so `ascii_angle` rewrote it to `-`/`|` (e.g. "C++" -> "C--"). The
# fix keeps a four-arm `+` intact unless at least two neighbors reciprocate.
describe "Docking ASCII mode (text '+', BUGS15 #30)" do
  it "keeps a text '+' adjacent to another '+' (single reciprocating arm)" do
    Docking.angle_at(grid(["C++"]), 1, 0, DockContrast::Ignore, ascii: true).should eq '+'
    Docking.angle_at(grid(["C++"]), 2, 0, DockContrast::Ignore, ascii: true).should eq '+'
  end

  it "does not mangle 'C++' during a full ascii dock pass" do
    g = grid ["C++"]
    Docking.dock(g, {0 => true}, 3, DockContrast::Ignore, ascii: true)
    String.build { |io| g[0].chars.each { |c| io << c } }.should eq "C++"
  end

  it "still merges a genuine ascii junction with two or more arms" do
    # Full four-way ascii cross stays '+'.
    cross = grid [
      " | ",
      "-+-",
      " | ",
    ]
    Docking.angle_at(cross, 1, 1, DockContrast::Ignore, ascii: true).should eq '+'
    # A tee (left+right+down arms) also renders as '+'.
    Docking.angle_at(grid(["-+-", " | "]), 1, 0, DockContrast::Ignore, ascii: true).should eq '+'
  end

  it "leaves plain '-' and '|' text runs untouched" do
    Docking.angle_at(grid(["a--b"]), 1, 0, DockContrast::Ignore, ascii: true).should eq '-'
    Docking.angle_at(grid(["|", "|"]), 0, 0, DockContrast::Ignore, ascii: true).should eq '|'
  end
end

# #42 — `Widget::Line#register_dock_stops` wrote its horizontal-line rows to the
# base `_dock_stops` unconditionally, ignoring the compositing-plane gate the
# base implementation uses. A separator Line inside a z-indexed overlay then
# docked against base content below it. The fix routes through the same gate.
describe "Widget::Line#register_dock_stops (compositing plane, BUGS15 #42)" do
  it "routes an overlay Line's rows to the plane stops, not the base" do
    s = bugs15_dock_screen
    s.alloc

    # A z-indexed (layer) container holding a horizontal separator Line. The
    # container is deferred to a plane, so the Line's rows must land on the
    # plane stops and leave the base stops empty.
    outer = Widget::Box.new(parent: s, left: 5, top: 5, width: 12, height: 8)
    outer.style.z_index = 10
    Widget::HLine.new(parent: outer, top: 2, left: 1, width: 8)

    s._render

    s._dock_stops.empty?.should be_true
    s._plane_dock_stops.empty?.should be_false
  end

  it "routes a base-layer Line's rows to the base stops" do
    s = bugs15_dock_screen
    s.alloc

    Widget::HLine.new(parent: s, top: 3, left: 2, width: 8)

    s._render

    s._dock_stops.empty?.should be_false
  end
end
