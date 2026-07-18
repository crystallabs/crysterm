require "./spec_helper"

include Crysterm

# `gridline-color` (Qt) recolors a table's internal gridlines independently of
# the box border; `spacing` (Qt's layout spacing) sets the inter-child gap.
# These drive the full CSS pipeline and inspect rendered cells / positions.

private def render_screen
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 80, height: 24)
end

private def headless_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
end

private def cell_fg(screen, y, x)
  Crysterm::Attr.unpack_color(Crysterm::Attr.fg(screen.lines[y][x].attr))
end

private def count_cells_fg(screen, color)
  n = 0
  (0...screen.height).each do |y|
    next unless screen.lines[y]?
    (0...screen.width).each { |x| n += 1 if cell_fg(screen, y, x) == color }
  end
  n
end

describe "gridline-color" do
  it "parses onto the style" do
    screen = headless_screen
    table = Widget::Table.new rows: [["a", "b"], ["c", "d"]]
    screen.append table

    screen.stylesheet = "Table { gridline-color: #ff00ff; }"
    screen.apply_stylesheet

    table.styles.normal.gridline_color.should eq 0xff00ff
  end

  it "is a known property" do
    Crysterm::CSS::Properties.known?("gridline-color").should be_true
  end

  it "paints the table's internal gridlines in the requested color" do
    screen = render_screen
    Widget::Table.new parent: screen, top: 0, left: 0, width: 24,
      rows: [["aa", "bb"], ["11", "22"]]
    # Border enables gridline drawing; gridline-color recolors them.
    screen.stylesheet = "Table { border: solid; gridline-color: #ff00ff; }"
    screen._render

    count_cells_fg(screen, 0xff00ff).should be > 0
  end

  it "defaults gridlines to the border color when unset" do
    screen = render_screen
    Widget::Table.new parent: screen, top: 0, left: 0, width: 24,
      rows: [["aa", "bb"], ["11", "22"]]
    screen.stylesheet = "Table { border: solid; border-color: #00ff00; }"
    screen._render

    # No gridline-color -> gridlines follow the border fg.
    count_cells_fg(screen, 0x00ff00).should be > 0
    count_cells_fg(screen, 0xff00ff).should eq 0
  end
end

describe "spacing" do
  it "is a geometry property" do
    Crysterm::CSS::Geometry.handles?("spacing").should be_true
  end

  it "sets the layout gap from CSS" do
    screen = headless_screen
    box = Widget::Box.new parent: screen,
      layout: Layout::Box.new(orientation: Tput::Orientation::Horizontal)
    screen.stylesheet = "Box { spacing: 3; }"
    screen.apply_stylesheet

    box.layout.not_nil!.spacing.should eq 3
  end

  it "separates HBox children by the CSS spacing" do
    screen = render_screen
    box = Widget::Box.new parent: screen, top: 0, left: 0, width: 40, height: 6,
      layout: Layout::Box.new(orientation: Tput::Orientation::Horizontal)
    Widget::Box.new parent: box, width: 6, height: 4
    b = Widget::Box.new parent: box, width: 6, height: 4
    box.add_css_class "spaced"
    screen.stylesheet = ".spaced { spacing: 3; }"
    screen._render

    a = box.children[0]
    la = a.lpos.not_nil!
    lb = b.lpos.not_nil!
    # 3-cell gap between the two fixed children.
    (lb.xi - la.xl).should eq 3
  end

  it "is inherited on the Layout base so flow layouts accept it too" do
    # spacing lives on Layout, so a flow layout exposes the setter even though it
    # doesn't act on it. Guards the lifted-to-base refactor.
    Layout::Wrap.new.spacing.should eq 0
    Layout::Box.new.responds_to?(:spacing=).should be_true
  end
end
