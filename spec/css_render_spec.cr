require "./spec_helper"

include Crysterm

# End-to-end proof that CSS doesn't just populate `Style` objects but actually
# changes what gets drawn: it sets a stylesheet, runs a real synchronous render
# (`Screen#_render`, which applies the cascade then fills the cell buffer), and
# inspects the resulting packed attributes in `Screen#lines`.

private def render_screen
  Crysterm::Screen.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 80, height: 24)
end

private def cell_fg(screen, y, x)
  Crysterm::Attr.unpack_color(Crysterm::Attr.fg(screen.lines[y][x].attr))
end

private def cell_bg(screen, y, x)
  Crysterm::Attr.unpack_color(Crysterm::Attr.bg(screen.lines[y][x].attr))
end

describe "CSS end-to-end rendering" do
  it "paints CSS colors into the rendered cell buffer" do
    screen = render_screen
    Widget::Box.new parent: screen, top: 1, left: 1, width: 10, height: 5

    screen.stylesheet = "Box { background-color: #0000ff; color: #ff0000; }"
    screen._render # applies the cascade (dirty) and fills @lines

    # a cell well inside the box carries the CSS colors
    cell_bg(screen, 2, 3).should eq 0x0000ff
    cell_fg(screen, 2, 3).should eq 0xff0000
  end

  it "paints per-side border colors into the right edges" do
    screen = render_screen
    Widget::Box.new parent: screen, top: 0, left: 0, width: 10, height: 5

    screen.stylesheet = "Box { border: solid; border-top-color: #ff0000; border-bottom-color: #0000ff; }"
    screen._render

    cell_fg(screen, 0, 4).should eq 0xff0000 # top edge -> red
    cell_fg(screen, 4, 4).should eq 0x0000ff # bottom edge -> blue
  end

  it "paints per-cell table colors into the right columns" do
    screen = render_screen
    Widget::Table.new parent: screen, top: 0, left: 0, width: 24, rows: [["aa", "bb"], ["11", "22"]]

    screen.stylesheet = "Cell:nth-child(1) { color: #ff0000; } Cell:nth-child(2) { color: #0000ff; }"
    screen._render

    reds = [] of Int32
    blues = [] of Int32
    (0...24).each do |y|
      next unless screen.lines[y]?
      (0...24).each do |x|
        case cell_fg(screen, y, x)
        when 0xff0000 then reds << x
        when 0x0000ff then blues << x
        end
      end
    end

    reds.should_not be_empty
    blues.should_not be_empty
    reds.max.not_nil!.should be < blues.min.not_nil! # red column left of blue column
  end

  it "paints per-cell ListTable colors into the right columns" do
    screen = render_screen
    Widget::ListTable.new parent: screen, top: 0, left: 0, width: 24, rows: [["aa", "bb"], ["11", "22"]]

    screen.stylesheet = "Cell:nth-child(1) { color: #ff0000; } Cell:nth-child(2) { color: #0000ff; }"
    screen._render

    reds = [] of Int32
    blues = [] of Int32
    (0...24).each do |y|
      next unless screen.lines[y]?
      (0...24).each do |x|
        case cell_fg(screen, y, x)
        when 0xff0000 then reds << x
        when 0x0000ff then blues << x
        end
      end
    end

    reds.should_not be_empty
    blues.should_not be_empty
    reds.max.not_nil!.should be < blues.min.not_nil! # red column left of blue column
  end

  it "reflects a restyle in the next render" do
    screen = render_screen
    box = Widget::Box.new parent: screen, top: 1, left: 1, width: 10, height: 5

    screen.stylesheet = <<-CSS
      Box { background-color: #0000ff; }
      .hot { background-color: #00ff00; }
    CSS
    screen._render
    cell_bg(screen, 2, 3).should eq 0x0000ff

    # add a class -> auto-invalidates -> next render repaints with the new rule
    box.add_css_class "hot"
    screen._render
    cell_bg(screen, 2, 3).should eq 0x00ff00
  end
end
