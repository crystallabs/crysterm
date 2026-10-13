require "./spec_helper"

include Crysterm

# A picture the terminal draws apart from the cells (Kitty) or after them
# (sixel, iTerm2) used to land on top of a menu, a torn-off menu or a dialog
# opened over it. It now presents only the cells nothing stacked above it
# covers (`Widget#visible_region`): Kitty places the uncovered parts of the
# image it already holds, the cell-drawing backends draw each uncovered part
# as a picture of its own, and closing what covered it brings it back whole —
# no pixels sent again for Kitty.

private def occl_window(output : IO::Memory, w = 40, h = 12)
  Window.new(input: IO::Memory.new, output: output, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

private def solid(w = 16, h = 16) : PNGGIF::Bitmap
  Array.new(h) { Array.new(w) { PNGGIF::Pixel.new(200u8, 10u8, 10u8, 255u8) } }
end

# The output of one repaint of *s*.
private def frame(s : Window, buf : IO::Memory) : String
  buf.clear
  s.repaint
  buf.to_s
end

# The kitty placement commands (`a=p`) in *emitted*, as their key strings.
private def placements(emitted : String) : Array(String)
  emitted.scan(/\e_Ga=p,([^;\e]*)\e\\/).map(&.[1])
end

# A box standing in for a popup (an opaque, filled widget), over cells
# (*left*, *top*) .. of the window.
private def popup_box(s, left, top, width, height, style = Style.new(bg: "blue"))
  Widget::Box.new parent: s, left: left, top: top, width: width, height: height,
    content: "menu", style: style
end

private def kitty(s)
  k = Widget::Media::Kitty.new parent: s, top: 1, left: 2, width: 8, height: 4,
    cell_pixel_width: 10, cell_pixel_height: 20
  k.bitmap = solid
  k
end

describe Region do
  it "subtracts a rectangle into disjoint parts, and compares by value" do
    r = Region.new(Rect.new(0, 0, 8, 4)).subtracted(Rect.new(2, 1, 3, 1))
    r.rects.should eq [Rect.new(0, 0, 8, 1), Rect.new(0, 1, 2, 1), Rect.new(5, 1, 3, 1), Rect.new(0, 2, 8, 2)]
    r.area.should eq 29
    r.should eq Region.new(Rect.new(0, 0, 8, 4)).subtracted(Rect.new(2, 1, 3, 1))
    r.subtracted(Rect.new(-5, -5, 20, 20)).empty?.should be_true
    Region.new(Rect.new(0, 0, 4, 4)).subtracted(Rect.new(10, 10, 1, 1)).rects.should eq [Rect.new(0, 0, 4, 4)]
  end
end

describe "Widget#visible_region" do
  it "takes away what paints above the widget, on its layer or a higher one, not what paints below" do
    buf = IO::Memory.new
    s = occl_window buf
    below = popup_box s, 0, 0, 5, 3
    k = kitty s
    frame s, buf
    k.visible_region.should eq Region.new(Rect.new(2, 1, 8, 4))
    above = popup_box s, 4, 2, 3, 1
    layered = popup_box s, 0, 0, 3, 2, style: Style.new(bg: "red", z_index: 5)
    layered.to_back
    frame s, buf
    k.visible_region.should eq Region.new(Rect.new(2, 1, 8, 4))
      .subtracted(Rect.new(4, 2, 3, 1)).subtracted(Rect.new(0, 0, 3, 2))
    above.hide
    layered.hide
    frame s, buf
    k.visible_region.should eq Region.new(Rect.new(2, 1, 8, 4))
    below.destroy
  ensure
    s.try &.destroy
  end
end

describe "Media::Kitty under a popup" do
  it "places only the uncovered parts while covered, and the whole picture again after, sending no pixels" do
    buf = IO::Memory.new
    s = occl_window buf
    k = kitty s
    frame(s, buf).should contain("\e_Ga=T")
    menu = popup_box s, 4, 2, 3, 1
    emitted = frame s, buf
    emitted.should_not contain("\e_Ga=T")
    emitted.should_not contain("\e_Ga=t")
    ps = placements emitted
    ps.size.should eq 4
    id = k.@placed_id.not_nil!
    # Above the menu: the full width, image pixels 0..160 x 0..32 (16x16 px
    # source over 8x4 cells: 2 px a column, 4 a row).
    ps[0].should eq "i=#{id},p=1,x=0,y=0,w=16,h=4,c=8,r=1,C=1,q=2"
    ps[1].should eq "i=#{id},p=2,x=0,y=4,w=4,h=4,c=2,r=1,C=1,q=2"
    ps[2].should eq "i=#{id},p=3,x=10,y=4,w=6,h=4,c=3,r=1,C=1,q=2"
    ps[3].should eq "i=#{id},p=4,x=0,y=8,w=16,h=8,c=8,r=2,C=1,q=2"
    # Each part is placed at its own cell: the first at the box's top-left,
    # the part right of the menu at row 3, column 8 (1-based).
    emitted.should contain("\e[2;3H\e_Ga=p,i=#{id},p=1,")
    emitted.should contain("\e[3;8H\e_Ga=p,i=#{id},p=3,")
    # The parts come after the frame's cells (the menu's among them).
    emitted.index!("men").should be < emitted.index!("\e_Ga=p")
    # The next frame sends the covered cells again (a terminal keeping
    # pictures in its cells erases its piece under them) and places the
    # parts around them again, still without pixels; then nothing changes.
    emitted = frame s, buf
    emitted.should contain("\e[3;5H\e[48;2;0;0;238mmen")
    emitted.should_not contain("\e_Ga=T")
    placements(emitted).size.should eq 4
    frame(s, buf).should_not contain("\e_G")

    menu.hide
    emitted = frame s, buf
    emitted.should_not contain("\e_Ga=T")
    placements(emitted).should eq ["i=#{id},p=1,c=8,r=4,C=1,q=2"]
    (2..4).each { |p| emitted.should contain("\e_Ga=d,d=i,i=#{id},p=#{p},q=2\e\\") }
    frame(s, buf).should_not contain("\e_G")
  ensure
    s.try &.destroy
  end

  it "follows a popup that moves, and drops every placement while covered whole" do
    buf = IO::Memory.new
    s = occl_window buf
    k = kitty s
    frame s, buf
    menu = popup_box s, 0, 0, 4, 6
    emitted = frame s, buf
    placements(emitted).size.should eq 1 # only the part right of the menu
    menu.left = 8
    emitted = frame s, buf
    emitted.should_not contain("\e_Ga=T")
    placements(emitted).size.should eq 1 # only the part left of it now
    menu.left = 0
    menu.width = 20
    emitted = frame s, buf
    id = k.@placed_id.not_nil!
    placements(emitted).should be_empty
    emitted.should contain("\e_Ga=d,d=i,i=#{id},p=1,q=2\e\\")
    emitted.should_not contain("\e_Ga=T")
    menu.hide
    emitted = frame s, buf
    emitted.should_not contain("\e_Ga=T")
    placements(emitted).should eq ["i=#{id},p=1,c=8,r=4,C=1,q=2"]
  ensure
    s.try &.destroy
  end

  it "sends a picture that first appears covered without placing it, then places its parts" do
    buf = IO::Memory.new
    s = occl_window buf
    k = Widget::Media::Kitty.new parent: s, top: 1, left: 2, width: 8, height: 4,
      cell_pixel_width: 10, cell_pixel_height: 20, double_buffer: false
    popup_box s, 4, 2, 3, 1
    k.bitmap = solid
    emitted = frame s, buf
    emitted.should_not contain("\e_Ga=T")
    emitted.should contain("\e_Ga=t,f=32,s=16,v=16,i=#{k.@id_a},q=2,")
    emitted.should_not contain(",p=1,c=8,r=4")
    placements(emitted).size.should eq 4
    emitted.index!("\e_Ga=t").should be < emitted.index!("\e_Ga=p")
  ensure
    s.try &.destroy
  end

  it "keeps a popup menu and a torn-off menu above the picture" do
    buf = IO::Memory.new
    s = occl_window buf, 60, 20
    k = Widget::Media::Kitty.new parent: s, top: 1, left: 2, width: 30, height: 12,
      cell_pixel_width: 10, cell_pixel_height: 20
    k.bitmap = solid
    frame s, buf
    menu = Widget::Menu.new window: s, style: Style.new(border: true)
    menu.add_action("Copy") { }
    menu.add_action("Paste") { }
    menu.popup 5, 3
    emitted = frame s, buf
    emitted.should_not contain("\e_Ga=T")
    placements(emitted).size.should be > 1
    lp = menu.lpos.not_nil!
    k.visible_region.rects.none?(&.intersects?(Rect.of_edges(lp.xi, lp.yi, lp.xl, lp.yl))).should be_true
    torn = menu.tear_off
    menu.hide
    torn.move 10, 6
    emitted = frame s, buf
    emitted.should_not contain("\e_Ga=T")
    tp = torn.lpos.not_nil!
    k.visible_region.rects.none?(&.intersects?(Rect.of_edges(tp.xi, tp.yi, tp.xl, tp.yl))).should be_true
    placements(emitted).size.should be > 1
    torn.destroy
    emitted = frame s, buf
    emitted.should_not contain("\e_Ga=T")
    placements(emitted).should eq ["i=#{k.@placed_id},p=1,c=30,r=12,C=1,q=2"]
  ensure
    s.try &.destroy
  end
end

describe "Media::Sixel under a popup" do
  it "draws each uncovered part as a sixel at its own cell, and the whole picture once uncovered" do
    buf = IO::Memory.new
    s = occl_window buf
    sx = Widget::Media::Sixel.new parent: s, top: 1, left: 2, width: 8, height: 4,
      cell_pixel_width: 10, cell_pixel_height: 20
    sx.bitmap = solid
    emitted = frame s, buf
    emitted.scan("\eP0;1;0q").size.should eq 1
    emitted.should contain("\e[2;3H\eP0;1;0q\"1;1;80;80")
    menu = popup_box s, 4, 2, 3, 1
    emitted = frame s, buf
    emitted.scan("\eP0;1;0q").size.should eq 4
    emitted.should contain("\e[2;3H\eP0;1;0q\"1;1;80;20") # above the menu
    emitted.should contain("\e[3;3H\eP0;1;0q\"1;1;20;20") # left of it
    emitted.should contain("\e[3;8H\eP0;1;0q\"1;1;30;20") # right of it
    emitted.should contain("\e[4;3H\eP0;1;0q\"1;1;80;40") # below it
    emitted.index!("men").should be < emitted.index!("\eP0;1;0q")
    # Re-emitted every frame, as a whole sixel is, from the cached parts.
    frame(s, buf).scan("\eP0;1;0q").size.should eq 4
    menu.hide
    emitted = frame s, buf
    emitted.scan("\eP0;1;0q").size.should eq 1
    emitted.should contain("\e[2;3H\eP0;1;0q\"1;1;80;80")
  ensure
    s.try &.destroy
  end
end

describe "a cell-drawing picture under a popup with blank cells" do
  it "sends the popup's blank cells again, which equal the blanks under the picture" do
    buf = IO::Memory.new
    s = occl_window buf
    sx = Widget::Media::Sixel.new parent: s, top: 1, left: 2, width: 8, height: 4,
      cell_pixel_width: 10, cell_pixel_height: 20
    sx.bitmap = solid
    frame s, buf
    # Default colors, no text: its cells are the very blanks the window
    # holds under the picture, so the frame that shows it sends none.
    blank = Widget::Box.new parent: s, left: 4, top: 2, width: 3, height: 1
    frame(s, buf).should_not contain("\e[3;5H")
    emitted = frame s, buf
    emitted.should contain("\e[3;5H   ")
    emitted.index!("\e[3;5H").should be < emitted.index!("\eP0;1;0q")
    frame(s, buf).should_not contain("\e[3;5H")
    blank.destroy
  ensure
    s.try &.destroy
  end
end

describe "Media::Iterm under a popup" do
  it "draws each uncovered part as an inline image stretched over its cells" do
    buf = IO::Memory.new
    s = occl_window buf
    path = File.tempname("occl", ".png")
    File.write path, PNGGIF.encode_png(solid)
    it = Widget::Media::Iterm.new file: path, parent: s, top: 1, left: 2, width: 8, height: 4,
      cell_pixel_width: 10, cell_pixel_height: 20
    emitted = frame s, buf
    emitted.scan("\e]1337;File=").size.should eq 1
    menu = popup_box s, 4, 2, 3, 1
    emitted = frame s, buf
    emitted.scan("\e]1337;File=").size.should eq 4
    emitted.should contain(";width=8;height=1;preserveAspectRatio=0:")
    emitted.should contain(";width=3;height=1;preserveAspectRatio=0:")
    emitted.should contain("\e[3;8H\e]1337;File=")
    menu.hide
    emitted = frame s, buf
    emitted.scan("\e]1337;File=").size.should eq 1
    emitted.should contain(";width=8;height=4;")
    it.destroy
  ensure
    path.try { |p| File.delete? p }
    s.try &.destroy
  end
end

describe "external overlay helpers under a popup" do
  it "takes the Ueberzug placement down while covered and adds it again once uncovered" do
    buf = IO::Memory.new
    s = occl_window buf
    path = File.tempname("occl", ".png")
    File.write path, PNGGIF.encode_png(solid)
    uz = Widget::Media::Ueberzug.new file: path, parent: s, top: 1, left: 2, width: 8, height: 4
    frame s, buf
    uz.@last.should eq({2, 1, 8, 4})
    menu = popup_box s, 4, 2, 3, 1
    frame s, buf
    uz.@last.should be_nil
    menu.hide
    frame s, buf
    uz.@last.should eq({2, 1, 8, 4})
    uz.destroy
  ensure
    path.try { |p| File.delete? p }
    s.try &.destroy
  end

  it "takes the w3m picture down while covered, without asking the helper to draw" do
    buf = IO::Memory.new
    s = occl_window buf
    path = File.tempname("occl", ".png")
    File.write path, PNGGIF.encode_png(solid)
    ov = Widget::Media::Overlay.new file: path, parent: s, top: 1, left: 2, width: 8, height: 4
    popup_box s, 4, 2, 3, 1
    frame s, buf
    ov.@last_drawn.should be_nil
    ov.helper_failed?.should be_false # never tried to draw
    ov.destroy
  ensure
    path.try { |p| File.delete? p }
    s.try &.destroy
  end
end
