require "./spec_helper"

include Crysterm

# Regression specs for BUGS15:
#
#  #75 Negative CSS padding is an invalid declaration and must be dropped
#      (both the `padding` shorthand and the four per-side longhands), unlike
#      margin, where negative values are legitimate CSS and kept.
#
#  #76 `alternate-background-color` must change ONLY the background of alternate
#      rows; the text color must follow the element's current color, so a later
#      `color` declaration (any order) and an inherited color both reach
#      alternate rows. The old code froze the cell/self style at declaration
#      time, leaving alternate rows without the color.

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

# Count cells that carry BOTH the given foreground and background.
private def count_cells_fg_bg(screen, fg, bg)
  n = 0
  (0...screen.height).each do |y|
    next unless screen.lines[y]?
    (0...screen.width).each do |x|
      n += 1 if cell_fg(screen, y, x) == fg && cell_bg(screen, y, x) == bg
    end
  end
  n
end

describe "BUGS15 #75 negative padding is dropped/clamped" do
  it "drops a negative single-value padding shorthand (clamps all sides to 0)" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "padding", "-1")
    s.padding.left.should eq 0
    s.padding.top.should eq 0
    s.padding.right.should eq 0
    s.padding.bottom.should eq 0
  end

  it "clamps only the negative side of a mixed padding shorthand" do
    s = Style.new
    # CSS TRBL: top=2 right=-1 bottom=3 left=4
    Crysterm::CSS::Properties.apply(s, "padding", "2 -1 3 4")
    s.padding.top.should eq 2
    s.padding.right.should eq 0 # was -1, clamped
    s.padding.bottom.should eq 3
    s.padding.left.should eq 4
  end

  it "drops a negative per-side padding longhand, keeping the previous value" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "padding-left", "2")
    Crysterm::CSS::Properties.apply(s, "padding-left", "-3")
    s.padding.left.should eq 2 # negative dropped, prior value kept
  end

  it "keeps the default when a negative longhand is the only declaration" do
    s = Style.new
    default = s.padding.top
    Crysterm::CSS::Properties.apply(s, "padding-top", "-2")
    s.padding.top.should eq default
    s.padding.top.should be >= 0
  end

  it "still accepts non-negative padding values" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "padding", "1 2 3 4")
    s.padding.top.should eq 1
    s.padding.right.should eq 2
    s.padding.bottom.should eq 3
    s.padding.left.should eq 4

    Crysterm::CSS::Properties.apply(s, "padding-left", "5")
    s.padding.left.should eq 5
  end

  it "leaves negative margin untouched (valid CSS)" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "margin", "-1")
    s.margin.left.should eq -1
    s.margin.top.should eq -1

    Crysterm::CSS::Properties.apply(s, "margin-left", "-2")
    s.margin.left.should eq -2
  end
end

describe "BUGS15 #76 alternate-background-color changes only the background" do
  # Style-level: text color declared AFTER alternate-background-color must still
  # reach alternate rows (the freeze bug).
  it "composes a later color declaration onto alternate rows" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "alternate-background-color", "#333333")
    Crysterm::CSS::Properties.apply(s, "color", "#ff0000")
    alt = s.alternate_row
    alt.bg.should eq 0x333333
    alt.fg.should eq 0xff0000
  end

  it "gives the same result when color is declared first" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "color", "#ff0000")
    Crysterm::CSS::Properties.apply(s, "alternate-background-color", "#333333")
    alt = s.alternate_row
    alt.bg.should eq 0x333333
    alt.fg.should eq 0xff0000
  end

  it "reports alternate_row? once an alternate-background-color is set" do
    s = Style.new
    s.alternate_row?.should be_false
    Crysterm::CSS::Properties.apply(s, "alternate-background-color", "#333333")
    s.alternate_row?.should be_true
    s.alternate_background_color.should eq 0x333333
  end

  # End-to-end through the real cascade + render.
  it "renders alternate Table rows with red text on the #333 background (bg before color)" do
    screen = render_screen
    Widget::Table.new parent: screen, top: 0, left: 0, width: 24,
      rows: [["h1", "h2"], ["a", "b"], ["c", "d"], ["e", "f"]], alternate_rows: true
    screen.stylesheet = "Table { alternate-background-color: #333333; color: #ff0000; }"
    screen._render

    count_cells_fg_bg(screen, 0xff0000, 0x333333).should be > 0
  end

  it "renders the same result with the declaration order reversed" do
    screen = render_screen
    Widget::Table.new parent: screen, top: 0, left: 0, width: 24,
      rows: [["h1", "h2"], ["a", "b"], ["c", "d"], ["e", "f"]], alternate_rows: true
    screen.stylesheet = "Table { color: #ff0000; alternate-background-color: #333333; }"
    screen._render

    count_cells_fg_bg(screen, 0xff0000, 0x333333).should be > 0
  end

  it "lets a color inherited from a parent-scope rule reach alternate rows" do
    screen = render_screen
    wrap = Widget::Box.new parent: screen, top: 0, left: 0, width: 24, height: 12
    wrap.css_id = "wrap"
    Widget::Table.new parent: wrap, top: 0, left: 0, width: 24,
      rows: [["h1", "h2"], ["a", "b"], ["c", "d"], ["e", "f"]], alternate_rows: true
    # The color matches only the parent (id selector), so it must INHERIT down
    # to the Table and its alternate rows; the Table rule sets only the bg.
    screen.stylesheet = <<-CSS
    #wrap { color: #ff0000; }
    Table { alternate-background-color: #333333; }
    CSS
    screen._render

    count_cells_fg_bg(screen, 0xff0000, 0x333333).should be > 0
  end
end
