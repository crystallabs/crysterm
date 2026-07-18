require "./spec_helper"

include Crysterm

# End-to-end proof that CSS actually changes what gets drawn: sets a
# stylesheet, runs a real synchronous render (`Window#_render`, which applies
# the cascade then fills the cell buffer), and inspects the packed attributes
# in `Window#lines`.

private def render_screen
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 80, height: 24)
end

private def cell_fg(screen, y, x)
  Crysterm::Attr.unpack_color(Crysterm::Attr.fg(screen.lines[y][x].attr))
end

private def cell_bg(screen, y, x)
  Crysterm::Attr.unpack_color(Crysterm::Attr.bg(screen.lines[y][x].attr))
end

private def count_cells_bg(screen, color)
  n = 0
  (0...screen.height).each do |y|
    next unless screen.lines[y]?
    (0...screen.width).each { |x| n += 1 if cell_bg(screen, y, x) == color }
  end
  n
end

describe "CSS end-to-end rendering" do
  it "paints CSS colors into the rendered cell buffer" do
    screen = render_screen
    Widget::Box.new parent: screen, top: 1, left: 1, width: 10, height: 5

    screen.stylesheet = "Box { background-color: #0000ff; color: #ff0000; }"
    screen._render # applies the cascade (dirty) and fills @lines

    # cell inside the box carries the CSS colors
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

  it "paints alternate-background-color onto alternating Table rows" do
    screen = render_screen
    Widget::Table.new parent: screen, top: 0, left: 0, width: 24,
      rows: [["h1", "h2"], ["a", "b"], ["c", "d"], ["e", "f"]], alternate_rows: true
    screen.stylesheet = "Table { alternate-background-color: #00ff00; }"
    screen._render

    greens = count_cells_bg(screen, 0x00ff00)
    greens.should be > 0
  end

  it "paints alternate-background-color onto alternating ListTable rows" do
    # ListTable renders rows via the per-item CSS path (focusable), exercising
    # the overlay bridge, not Table's direct cell fill.
    screen = render_screen
    Widget::ListTable.new parent: screen, top: 0, left: 0, width: 24,
      rows: [["h1", "h2"], ["a", "b"], ["c", "d"], ["e", "f"]], alternate_rows: true
    screen.stylesheet = "ListTable { alternate-background-color: #00ff00; }"
    screen._render

    greens = count_cells_bg(screen, 0x00ff00)
    greens.should be > 0
  end

  it "paints selection-background-color onto the selected List item" do
    screen = render_screen
    list = Widget::List.new parent: screen, top: 0, left: 0, width: 20, height: 6,
      items: ["one", "two", "three"]
    list.current_index = 1
    screen.stylesheet = "List { selection-background-color: #ff00ff; }"
    screen._render

    magentas = count_cells_bg(screen, 0xff00ff)
    magentas.should be > 0
  end

  it "paints Menu::separator color onto the separator rule row" do
    screen = render_screen
    menu = Widget::Menu.new width: 20
    menu.add "Open"
    menu.add_separator
    menu.add "Quit"
    screen.append menu
    # opacity: 1.0 cancels the theme's translucent Menu plane so the separator
    # fg is exact rather than alpha-blended
    screen.stylesheet = "Menu { opacity: 1.0; } Menu::separator { color: #ff00ff; }"
    screen._render

    # the separator rule (a run of '─') is drawn from the separator sub-style
    magentas = 0
    (0...screen.height).each do |y|
      next unless screen.lines[y]?
      (0...screen.width).each { |x| magentas += 1 if cell_fg(screen, y, x) == 0xff00ff }
    end
    magentas.should be > 0
  end

  it "paints TabWidget::tab color onto the tab strip" do
    screen = render_screen
    tabs = Widget::TabWidget.new width: 40, height: 10
    tabs.add_tab "One", Widget::Box.new
    tabs.add_tab "Two", Widget::Box.new
    screen.append tabs
    screen.stylesheet = "TabWidget::tab { color: #ff00ff; }"
    screen._render

    # the tab labels in the strip are drawn from the pushed tab sub-style
    magentas = 0
    (0...screen.height).each do |y|
      next unless screen.lines[y]?
      (0...screen.width).each { |x| magentas += 1 if cell_fg(screen, y, x) == 0xff00ff }
    end
    magentas.should be > 0
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

    # adding a class auto-invalidates -> next render repaints with the new rule
    box.add_css_class "hot"
    screen._render
    cell_bg(screen, 2, 3).should eq 0x00ff00
  end
end
