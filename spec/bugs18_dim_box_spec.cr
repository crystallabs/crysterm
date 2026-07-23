require "./spec_helper"

include Crysterm

# Regression specs for the BUGS18 dim/box/docking batch:
#
# * B18-22 — `Dim#resolve`/`#resolve_viewport` and `CSS::Length.to_cell_count`
#   let `0 * ±Infinity == NaN` slip through their comparison-based clamps
#   (every comparison against NaN is false) straight to `.to_i`, raising
#   `OverflowError` in the render fiber. Neutralized to 0 before the clamp.
# * B18-23 — `Layout::Box` never released a stretch-assigned cross size once
#   `align` moved off `Stretch`: the child stayed frozen at the stale
#   assigned Int forever and the user's raw `nil` (auto) was destroyed.
# * B18-25 — `Layout::Box` accumulated a child's own unclamped fixed
#   main-axis size, overflowing checked `Int32` with a pathological
#   (`Int32::MAX`) child; the generic `Widget#coords` far-edge addition had
#   the same unchecked class for a nonzero absolute origin.
# * B18-26 — the typed `Dim.percent`/`Dim.center` constructors stored any
#   `Int32` offset raw (no B17-05-style saturation), so `v.to_i + @offset`
#   overflowed checked Int32 in `#resolve`.
# * B18-27 — `Dim#resolve_viewport` had the same NaN-through-clamp hole as
#   `#resolve` (B18-22), reachable via a NaN typed viewport percent or an
#   infinite percent against a 0-sized window edge.
# * B18-28 — ASCII docking's single-reciprocation text guard covered only a
#   full four-arm `+`; a text `-`/`|` beside a perpendicular single
#   reciprocating neighbor (e.g. a border `+` directly above) was silently
#   rewritten to `|`/`-`.

private def headless_screen(w = 80, h = 24)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

private def grid(rows : Array(String), attr : Int64 = 0_i64) : Array(Crysterm::Window::Row)
  rows.map do |s|
    row = Crysterm::Window::Row.new
    s.each_char { |c| row.push attr, c }
    row
  end
end

describe "BUGS18 B18-22: Dim#resolve / #resolve_viewport / Length.to_cell_count NaN guard" do
  it "does not raise when a huge string-percentage child resolves against a 0 content width" do
    s = headless_screen
    # Bordered parent: border-box width 2, content width 2 - 1 - 1 = 0.
    parent = Widget::Box.new parent: s, left: 0, top: 0, width: 2, height: 5,
      style: Style.new(border: true)
    huge = "9" * 320 # saturates to Float64::INFINITY while parsing (B17-05)
    Widget::Box.new parent: parent, width: "#{huge}%", height: 1
    s.repaint # pre-fix: 0 * INFINITY = NaN -> OverflowError in the render fiber
  end

  it "Dim#resolve returns 0 for a 0 extent with an infinite percent (direct)" do
    Dim.percent(Float64::INFINITY).resolve(0).should eq 0
    Dim.percent(-Float64::INFINITY).resolve(0).should eq 0
  end

  it "Dim#resolve_viewport returns 0 for a NaN typed percent" do
    Dim.vw(Float64::NAN).resolve_viewport(80, 24).should eq 0
  end

  it "Dim#resolve_viewport returns 0 for an infinite percent against a 0-sized window edge" do
    Dim.vw(Float64::INFINITY).resolve_viewport(0, 24).should eq 0
    Dim.vw(-Float64::INFINITY).resolve_viewport(0, 24).should eq 0
  end

  it "does not raise when a widget is sized with Dim.vw(NaN)" do
    s = headless_screen
    Widget::Box.new parent: s, width: Dim.vw(Float64::NAN), height: 1
    s.repaint
  end

  it "CSS::Length.to_cell_count neutralizes NaN instead of raising" do
    Crysterm::CSS::Length.to_cell_count(Float64::NAN).should eq 0
  end

  it "CSS::Length.calc reaching Infinity * 0 does not raise (NaN guard)" do
    # Twenty huge multiplicative terms overflow to Infinity; the trailing
    # `* 0` then produces NaN. calc funnels its result through
    # to_cell_count, whose NaN guard neutralizes it to 0 (the same
    # neutral value to_cells/viewport_cells produce for a NaN result)
    # rather than raising OverflowError.
    huge_chain = (["99999999999999999"] * 20).join(" * ")
    Crysterm::CSS::Length.calc("#{huge_chain} * 0").should eq 0
  end
end

describe "BUGS18 B18-26: Dim typed offset overflow guard" do
  it "does not raise when left is Dim.percent(50, Int32::MAX)" do
    s = headless_screen
    Widget::Box.new parent: s, left: Dim.percent(50, Int32::MAX), top: 0,
      width: 5, height: 1
    s.repaint # pre-fix: v.to_i + Int32::MAX overflows checked Int32
  end

  it "does not raise when left is Dim.center(Int32::MAX)" do
    s = headless_screen
    Widget::Box.new parent: s, left: Dim.center(Int32::MAX), top: 0,
      width: 5, height: 1
    s.repaint
  end

  it "clamps the resolved value instead of overflowing (direct)" do
    Dim.percent(50, Int32::MAX).resolve(80).should eq 1_000_000_000
    Dim.percent(50, Int32::MIN).resolve(80).should eq -1_000_000_000
  end

  it "keeps an ordinary typed offset exact (no regression)" do
    Dim.percent(50, -2).resolve(80).should eq 38
  end
end

describe "BUGS18 B18-23: Layout::Box releases a stretch-assigned cross size" do
  it "restores auto (nil) height once align moves off Stretch, tracking a shrunk container" do
    s = headless_screen
    box = Widget::Box.new parent: s, left: 0, top: 0, width: 30, height: 20,
      layout: (l = Layout::HBox.new)
    child = Widget::Box.new parent: box, width: 10 # height nil (auto)

    s.repaint
    child.height.should eq 20 # Stretch fills the 20-tall interior

    l.align = Layout::Box::Align::Start
    box.height = 10
    s.repaint

    # Post-fix: the child's raw height is restored to nil before re-measure,
    # so it re-resolves like a fresh auto-height child instead of staying
    # frozen at the stale assigned 20.
    child.height.should be_nil
    child.aheight.should eq 10
  end

  it "re-manages the child cleanly if align switches back to Stretch" do
    s = headless_screen
    box = Widget::Box.new parent: s, left: 0, top: 0, width: 30, height: 20,
      layout: (l = Layout::HBox.new)
    child = Widget::Box.new parent: box, width: 10

    s.repaint
    child.aheight.should eq 20

    l.align = Layout::Box::Align::Start
    box.height = 10
    s.repaint
    child.aheight.should eq 10

    l.align = Layout::Box::Align::Stretch
    box.height = 30
    s.repaint
    child.aheight.should eq 30
  end
end

describe "BUGS18 B18-25: Box/Form clamp a child's fixed main size; coords saturates" do
  it "does not raise with a 10-wide and an Int32::MAX-wide child under HBox" do
    s = headless_screen
    box = Widget::Box.new parent: s, left: 0, top: 0, width: 30, height: 5,
      layout: Layout::HBox.new
    Widget::Box.new parent: box, width: 10, height: 1
    Widget::Box.new parent: box, width: Int32::MAX, height: 1
    s.repaint # pre-fix: OverflowError at the `fixed += ms` sum in measure
  end

  it "does not raise with an Int32::MAX-tall child under VBox" do
    s = headless_screen
    box = Widget::Box.new parent: s, left: 0, top: 0, width: 5, height: 30,
      layout: Layout::VBox.new
    Widget::Box.new parent: box, width: 1, height: 10
    Widget::Box.new parent: box, width: 1, height: Int32::MAX
    s.repaint
  end

  it "does not raise for a Manual (no-layout) container at a nonzero left with a MAX-width child" do
    s = headless_screen
    parent = Widget::Box.new parent: s, left: 5, top: 0, width: 40, height: 5
    Widget::Box.new parent: parent, left: 0, top: 0, width: Int32::MAX, height: 1
    s.repaint # pre-fix: OverflowError at widget_position.cr's `xl = xi + w`
  end

  it "does not raise for a plain Manual child at left: 1 with a MAX-width size" do
    s = headless_screen
    Widget::Box.new parent: s, left: 1, top: 0, width: Int32::MAX, height: 1
    s.repaint
  end
end

describe "BUGS18 B18-28: ASCII docking preserves text '-'/'|' beside a perpendicular single recip" do
  it "keeps a text '-' below a border corner '+' intact" do
    g = grid [" + ", "x-y"]
    Docking.angle_at(g, 1, 1, DockContrast::Ignore, ascii: true).should eq '-'
  end

  it "does not mangle a hyphen during a full ascii dock pass" do
    g = grid [" + ", "x-y"]
    Docking.dock(g, {1 => true}, 3, DockContrast::Ignore, ascii: true)
    String.build { |io| g[1].chars.each { |c| io << c } }.should eq "x-y"
  end

  it "keeps a text '|' beside a horizontal border end intact" do
    g = grid ["|--"]
    Docking.angle_at(g, 0, 0, DockContrast::Ignore, ascii: true).should eq '|'
  end

  it "still merges a genuine border run-end junction ('-' below '+')" do
    g = grid ["+  ", "-- "]
    Docking.angle_at(g, 0, 1, DockContrast::Ignore, ascii: true).should eq '+'
  end

  it "still merges a genuine mid-run junction ('-' with '|' below)" do
    g = grid ["-+-", " | "]
    Docking.angle_at(g, 1, 0, DockContrast::Ignore, ascii: true).should eq '+'
  end

  it "keeps a text '+' adjacent to another '+' intact (no BUGS15 #30 regression)" do
    g = grid ["C++"]
    Docking.dock(g, {0 => true}, 3, DockContrast::Ignore, ascii: true)
    String.build { |io| g[0].chars.each { |c| io << c } }.should eq "C++"
  end
end
