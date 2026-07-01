require "./spec_helper"

include Crysterm

# Multi-plane compositor. A `Plane` is an independent screen-sized buffer;
# `#composite_onto` folds it over the base honoring per-cell `Attr::Alpha`
# modes plus a per-plane opacity. Tests drive it directly (no terminal) so
# resulting cell colors are exact.

private def sized_screen(w, h)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h)
end

private def bg_at(screen, y, x)
  Crysterm::Attr.unpack_color(Crysterm::Attr.bg(screen.lines[y][x].attr))
end

private def fill_base(screen, color)
  attr = Attr.pack(0, Attr::COLOR_DEFAULT, Attr.pack_color(color))
  screen.fill_region attr, ' ', 0, screen.awidth, 0, screen.aheight
end

private def paint(plane, x0, x1, attr)
  (0...plane.height).each do |y|
    row = plane.cells[y]
    (x0...x1).each do |x|
      c = row[x]
      c.attr = attr
      c.char = ' '
    end
    # Real widget paint marks every written row `dirty` (see `Widget#_render`);
    # `composite_onto` relies on that flag to skip untouched rows.
    row.dirty = true
  end
end

describe Crysterm::Plane do
  it "shows the base through unpainted (transparent) cells and replaces opaque ones" do
    s = sized_screen 20, 5
    fill_base s, 0x0000ff # blue base everywhere
    pl = Plane.new(0, 20, 5)
    pl.clear
    paint pl, 0, 10, Attr.pack(0, Attr::COLOR_DEFAULT, Attr.pack_color(0xff0000)) # red, opaque, left half
    pl.opacity = 1.0
    pl.composite_onto s.lines

    bg_at(s, 2, 5).should eq 0xff0000  # painted (opaque) -> red replaces base
    bg_at(s, 2, 15).should eq 0x0000ff # unpainted -> base shows through
  end

  it "blends a translucent layer over OTHER widgets' content (cross-widget see-through)" do
    s = sized_screen 20, 5
    fill_base s, 0x0000ff # blue base (as if painted by a different widget)
    pl = Plane.new(0, 20, 5)
    pl.clear
    paint pl, 0, 20, Attr.pack(0, Attr::COLOR_DEFAULT, Attr.pack_color(0xff0000)) # opaque red overlay
    pl.opacity = 0.5                                                              # ...but the plane is 50% -> red over blue
    pl.composite_onto s.lines

    bg_at(s, 2, 10).should eq 0x7f007f # mix(red, blue): base shows through overlay
  end

  it "honors per-cell Transparent and HighContrast alpha modes" do
    s = sized_screen 20, 3
    fill_base s, 0x0000ff
    pl = Plane.new(0, 20, 3)
    pl.clear
    # A painted cell with Transparent bg still shows the base through.
    transp = Attr.with_bg_alpha(Attr.pack(0, Attr::COLOR_DEFAULT, Attr.pack_color(0xff0000)), Attr::Alpha::Transparent)
    paint pl, 0, 5, transp
    # HighContrast bg recolors against the dark blue base -> a light shade.
    hc = Attr.with_bg_alpha(Attr.pack(0, Attr::COLOR_DEFAULT, Attr::COLOR_DEFAULT), Attr::Alpha::HighContrast)
    paint pl, 10, 15, hc
    pl.opacity = 1.0
    pl.composite_onto s.lines

    bg_at(s, 1, 2).should eq 0x0000ff  # Transparent bg -> base shows
    bg_at(s, 1, 12).should eq 0xf5f5f5 # HighContrast over dark -> near-white
  end
end

describe "CSS z-index auto-promotes a widget to a translucent layer" do
  it "composites a z-indexed overlay over another widget's content" do
    s = sized_screen 30, 6
    Widget::Box.new(parent: s, top: 0, left: 0, width: 30, height: 6).add_css_class "under"
    Widget::Box.new(parent: s, top: 0, left: 0, width: 30, height: 6).add_css_class "over"
    # `z-index` promotes `.over` to its own plane; `opacity` becomes the
    # plane's opacity, so the overlay blends over the base, all from CSS.
    s.stylesheet = ".under { background-color: #0000ff; } " \
                   ".over { background-color: #ff0000; z-index: 10; opacity: 0.5; }"
    s._render
    bg_at(s, 3, 10).should eq 0x7f007f # red @ 50% over blue
  end

  it "promotes a NESTED z-indexed widget to a plane, composited over its parent" do
    s = sized_screen 30, 6
    parent = Widget::Box.new parent: s, top: 0, left: 0, width: 30, height: 6
    parent.add_css_class "p"
    child = Widget::Box.new parent: parent, top: 0, left: 0, width: 30, height: 6
    child.add_css_class "c"
    s.stylesheet = ".p { background-color: #0000ff; } " \
                   ".c { background-color: #ff0000; z-index: 10; opacity: 0.5; }"
    s._render
    bg_at(s, 3, 10).should eq 0x7f007f # nested child blends over the parent's blue
  end
end
