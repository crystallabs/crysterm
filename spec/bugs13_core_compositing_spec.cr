require "./spec_helper"

include Crysterm

# Regression specs for BUGS13 core findings C13, C17, C22
# (src/docking.cr, src/plane.cr, src/window_rendering.cr + src/window_damage.cr):
#
# C13 — `DockContrast::Blend` must blend only the COLORS of a contrasting
#       neighbor into the junction cell: `Colors.blend` returns the FIRST
#       argument's flags, which used to transplant the neighbor's
#       reverse/bold/underline onto the docked cell.
# C17 — `Plane#composite_onto` must carry the OSC-8 link overlay both ways:
#       a layered widget's links fold onto the base, and an opaque overlay
#       cell CLEARS the base cell's old link (no bleed-through).
# C22 — same-z compositing groups fold each with their OWN alpha ({z, alpha}
#       buckets), not whichever layer root was collected first; mirrored in
#       the damage-tracking path (which falls back to the full path on
#       differing same-z alphas).

private def b13cp_window(w = 30, h = 6, damage = false)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false,
    optimization: damage ? Crysterm::OptimizationFlag::DamageTracking : Crysterm::OptimizationFlag::None)
end

# Builds an `Array(Row)` grid from rows of text, one cell per character, all
# with attribute *attr* (see spec/docking_spec.cr).
private def b13cp_grid(rows : Array(String), attr : Int64 = 0_i64) : Array(Crysterm::Window::Row)
  rows.map do |s|
    row = Crysterm::Window::Row.new
    s.each_char { |c| row.push attr, c }
    row
  end
end

private def b13cp_bg(s, y, x)
  Crysterm::Attr.unpack_color(Crysterm::Attr.bg(s.lines[y][x].attr))
end

describe "BUGS13 C13: DockContrast::Blend keeps the docked cell's own flags" do
  it "blends colors but does not transplant the neighbor's REVERSE onto the junction" do
    center = Attr.pack(Attr::BOLD, Attr.pack_color(0xff0000), Attr.pack_color(0x000000))
    neighbor = Attr.pack(Attr::REVERSE, Attr.pack_color(0x00ff00), Attr.pack_color(0xffffff))

    # Every cell carries the center's attr except the UP neighbor, which
    # contrasts (different colors AND a REVERSE flag the cell doesn't have).
    g = b13cp_grid [
      " │ ",
      "─│─",
      " │ ",
    ], center
    g[0][1].attr = neighbor

    Docking.angle_at(g, 1, 1, DockContrast::Blend).should eq '┼'

    docked = g[1][1].attr
    # The junction keeps its OWN flags: BOLD stays, the neighbor's REVERSE is
    # NOT transplanted (pre-fix `Colors.blend` returned the neighbor's flags).
    Attr.flags(docked).should eq Attr::BOLD
    # ...while the colors are still blended toward the neighbor's.
    blended = Colors.blend(neighbor, center)
    Attr.fg(docked).should eq Attr.fg(blended)
    Attr.bg(docked).should eq Attr.bg(blended)
  end
end

# C17 drives `Plane#composite_onto` directly (the plane_spec.cr harness): the
# fixed method is the whole compositor fold, so the base row's link overlay is
# the exact observable.
describe "BUGS13 C17: composite_onto carries the OSC-8 link overlay" do
  it "folds a plane cell's link onto the base row" do
    s = b13cp_window 20, 3
    begin
      pl = Plane.new(0, 20, 3)
      pl.clear
      row = pl.cells[1]
      cell = row[4]
      cell.attr = Attr.pack(0, Attr.pack_color(0xffffff), Attr.pack_color(0x333333))
      cell.char = 'L'
      row.set_link 4, 7_u16
      row.dirty = true

      pl.composite_onto s.lines

      s.lines[1].link_at(4).should eq 7_u16
      s.lines[1].has_links?.should be_true
    ensure
      s.destroy
    end
  end

  it "clears the base cell's old link under an opaque overlay cell (no bleed-through)" do
    s = b13cp_window 20, 3
    begin
      base = s.lines[1]
      base[4].char = 'x'
      base.set_link 4, 9_u16

      pl = Plane.new(0, 20, 3)
      pl.clear
      row = pl.cells[1]
      cell = row[4]
      cell.attr = Attr.pack(0, Attr.pack_color(0xffffff), Attr.pack_color(0x333333))
      cell.char = 'o' # opaque overlay cell WITHOUT a link
      row.dirty = true

      pl.composite_onto s.lines

      # Pre-fix the raw-array fold bypassed `Cell#char=`'s link-clear
      # invariant, so the overlay cell kept clicking as the base's old link.
      base.link_at(4).should eq 0_u16
      base.has_links?.should be_false
    ensure
      s.destroy
    end
  end

  it "writes through on a link-only difference (same glyph and attr)" do
    s = b13cp_window 20, 3
    begin
      attr = Attr.pack(0, Attr.pack_color(0xffffff), Attr.pack_color(0x333333))
      base = s.lines[1]
      base[4].attr = attr
      base[4].char = 'x'

      pl = Plane.new(0, 20, 3)
      pl.clear
      row = pl.cells[1]
      cell = row[4]
      cell.attr = attr # identical attr...
      cell.char = 'x'  # ...and glyph — only the link differs
      row.set_link 4, 5_u16
      row.dirty = true

      pl.composite_onto s.lines

      # Pre-fix the change test compared only attr/char/grapheme, so the
      # link-only difference was skipped and the link never reached the base.
      base.link_at(4).should eq 5_u16
    ensure
      s.destroy
    end
  end
end

# C22 scene: base blue underlay; two independent same-z (10) layer roots:
# `oa` is red at opacity 0.5, `ob` is green with no opacity (1.0). Each must
# fold with its own alpha regardless of declaration order — pre-fix the whole
# z-10 plane took whichever root was collected first.
private def b13cp_build_scene(s, oa_first : Bool)
  Widget::Box.new(parent: s, top: 0, left: 0, width: 30, height: 6).add_css_class "b13under"
  mk_oa = -> { Widget::Box.new(parent: s, top: 0, left: 2, width: 8, height: 4).add_css_class "b13oa" }
  mk_ob = -> { Widget::Box.new(parent: s, top: 0, left: 15, width: 8, height: 4).add_css_class "b13ob" }
  if oa_first
    mk_oa.call
    mk_ob.call
  else
    mk_ob.call
    mk_oa.call
  end
  s.stylesheet = ".b13under { background-color: #0000ff; } " \
                 ".b13oa { background-color: #ff0000; z-index: 10; opacity: 0.5; } " \
                 ".b13ob { background-color: #00ff00; z-index: 10; }"
end

describe "BUGS13 C22: same-z layers fold each with their OWN alpha" do
  it "applies each same-z root's own opacity" do
    s = b13cp_window
    begin
      b13cp_build_scene s, oa_first: true
      s.repaint
      b13cp_bg(s, 2, 5).should eq 0x7f007f  # red @ 0.5 over blue
      b13cp_bg(s, 2, 18).should eq 0x00ff00 # opaque green, NOT dragged to 0.5
    ensure
      s.destroy
    end
  end

  it "is declaration-order independent" do
    s = b13cp_window
    begin
      b13cp_build_scene s, oa_first: false
      s.repaint
      # Pre-fix, collecting `ob` first pinned the whole z-10 plane at ITS
      # alpha (1.0), flipping the result with declaration order.
      b13cp_bg(s, 2, 5).should eq 0x7f007f
      b13cp_bg(s, 2, 18).should eq 0x00ff00
    ensure
      s.destroy
    end
  end

  it "keeps per-root alphas across damage-tracked re-renders" do
    s = b13cp_window damage: true
    begin
      b13cp_build_scene s, oa_first: true
      lbl = Widget::Box.new parent: s, top: 5, left: 0, width: 8, height: 1, content: "aa"
      s.repaint
      b13cp_bg(s, 2, 5).should eq 0x7f007f
      b13cp_bg(s, 2, 18).should eq 0x00ff00

      # Mutate a base widget and re-render: the damage path may only take its
      # single-plane fast path when every same-z root shares one alpha; with
      # differing alphas it must fall back and keep both regions exact.
      lbl.content = "bb"
      s.repaint
      b13cp_bg(s, 2, 5).should eq 0x7f007f
      b13cp_bg(s, 2, 18).should eq 0x00ff00
    ensure
      s.destroy
    end
  end
end
