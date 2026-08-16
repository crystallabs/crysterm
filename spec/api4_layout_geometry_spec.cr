require "./spec_helper"

include Crysterm

# Coverage for the layout/geometry/docking polish: engine `spacing`, Grid
# per-track stretch/minimums, the generic Layout container API, Form row API,
# `layout:` symbols, main-axis spacers, spec-union `move`/`resize`, `Dim`
# comparison/arithmetic/`auto`, `Rectangle#x_end`/`#y_end` + value-object
# arithmetic, `Rectangle` region overloads, `Layout::Dock` hint sizes, and the
# `MainWindow` carve engine.

private def rect_of(w : Widget) : {Int32, Int32, Int32, Int32}
  lp = w.lpos.not_nil!
  {lp.xi, lp.yi, lp.width, lp.height}
end

describe "Layout#spacing" do
  it "separates Wrap children horizontally and rows vertically" do
    s = headless_screen(40, 12)
    c = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 12
    lay = c.layout = Layout::Wrap.new
    lay.spacing = 2
    a = Widget::Box.new parent: c, width: 6, height: 2
    b = Widget::Box.new parent: c, width: 6, height: 2
    d = Widget::Box.new parent: c, width: 12, height: 2 # wraps to row 2
    s.repaint

    ax, ay, _, _ = rect_of a
    bx, _, _, _ = rect_of b
    _, dy, _, _ = rect_of d
    (bx - ax).should eq 6 + 2 # horizontal gap
    (dy - ay).should eq 2 + 2 # row height + vertical gap
  ensure
    s.try &.destroy
  end

  it "separates a Dock edge band from the center" do
    s = headless_screen(40, 12)
    c = Widget::Box.new parent: s, top: 0, left: 0, width: 40, height: 12,
      layout: Layout::Dock.new
    c.layout.not_nil!.spacing = 1
    Widget::Box.new parent: c, height: 2, layout_hint: :top
    center = Widget::Box.new parent: c
    s.repaint

    _, cy, _, ch = rect_of center
    cy.should eq 3 # 2 rows consumed + 1 gap
    ch.should eq 12 - 3
  ensure
    s.try &.destroy
  end

  it "fans out to Form's horizontal/vertical pair" do
    f = Layout::Form.new
    f.spacing = 3
    f.horizontal_spacing.should eq 3
    f.vertical_spacing.should eq 3
  end
end

describe "Layout::Grid stretch and minimums" do
  it "gives a minimum-width track its cells and the stretch track the rest" do
    s = headless_screen(80, 10)
    c = Widget::Box.new parent: s, top: 0, left: 0, width: 80, height: 10
    g = Layout::Grid.new columns: 2
    c.layout = g
    g.set_column_minimum_width 0, 20
    g.set_column_stretch 1, 1
    sidebar = Widget::Box.new parent: c
    body = Widget::Box.new parent: c
    s.repaint

    rect_of(sidebar)[2].should eq 20
    rect_of(body)[2].should eq 60
    g.column_minimum_width(0).should eq 20
    g.column_stretch(1).should eq 1
  ensure
    s.try &.destroy
  end

  it "splits leftover by stretch weight" do
    s = headless_screen(60, 10)
    c = Widget::Box.new parent: s, top: 0, left: 0, width: 60, height: 10
    g = Layout::Grid.new columns: 2
    c.layout = g
    g.set_column_stretch 0, 1
    g.set_column_stretch 1, 2
    a = Widget::Box.new parent: c
    b = Widget::Box.new parent: c
    s.repaint

    rect_of(a)[2].should eq 20
    rect_of(b)[2].should eq 40
  ensure
    s.try &.destroy
  end
end

describe "generic Layout container API" do
  it "counts, indexes and removes arrangeable children" do
    s = headless_screen(40, 10)
    c = Widget::Box.new parent: s, top: 0, left: 0, width: 40, height: 10,
      layout: :vbox
    a = Widget::Box.new parent: c
    b = Widget::Box.new parent: c
    lay = c.layout.not_nil!

    lay.count.should eq 2
    lay.item_at(1).try(&.same?(b)).should be_true
    lay.index_of(b).should eq 1
    lay.index_of(Widget::Box.new).should eq -1
    lay.remove_widget(a).try(&.same?(a)).should be_true
    lay.count.should eq 1
    lay.index_of(a).should eq -1
  ensure
    s.try &.destroy
  end

  it "Form row_count/insert_row/remove_row manage pairs" do
    s = headless_screen(40, 10)
    c = Widget::Box.new parent: s, top: 0, left: 0, width: 40, height: 10
    f = Layout::Form.new
    c.layout = f
    f.add_row "Name", Widget::LineEdit.new
    mail = Widget::LineEdit.new
    f.add_row "Mail", mail
    f.row_count.should eq 2

    nick = Widget::LineEdit.new
    f.insert_row 1, "Nick", nick
    f.row_count.should eq 3
    f.item_at(3).try(&.same?(nick)).should be_true # its label sits at slot 2

    removed = f.remove_row 1
    removed.size.should eq 2
    removed[1].same?(nick).should be_true
    f.row_count.should eq 2
    f.item_at(3).try(&.same?(mail)).should be_true
  ensure
    s.try &.destroy
  end

  it "builds engines from symbols" do
    Layout.from(:vbox).is_a?(Layout::VBox).should be_true
    Layout.from(:flow).is_a?(Layout::Wrap).should be_true
    expect_raises(ArgumentError) { Layout.from(:nope) }
    s = headless_screen(20, 5)
    c = Widget::Box.new parent: s, layout: :grid
    c.layout.not_nil!.is_a?(Layout::Grid).should be_true
    c.layout = :dock
    c.layout.not_nil!.is_a?(Layout::Dock).should be_true
  ensure
    s.try &.destroy
  end
end

describe "Layout::Box#add_spacing" do
  it "pins only the main axis so the cross axis stretches" do
    s = headless_screen(30, 12)
    c = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 12,
      layout: :vbox
    lay = c.layout.not_nil!.as(Layout::Box)
    Widget::Box.new parent: c, height: 3
    sp = lay.add_spacing 5
    Widget::Box.new parent: c, height: 3
    s.repaint

    _, _, sw, sh = rect_of sp
    sh.should eq 5
    sw.should eq 20 # stretches across the box, no 5-cell hole
  ensure
    s.try &.destroy
  end
end

describe "Widget#move / #resize spec union" do
  it "accepts symbols and percent strings" do
    s = headless_screen(40, 10)
    b = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 4
    b.move :center, 0
    b.left.as(Crysterm::Dim).matches?(:center).should be_true
    b.resize "50%", 5
    b.width_spec.as(Crysterm::Dim).matches?("50%").should be_true
    b.resize Size.new(8, 3)
    b.width_spec.should eq 8
    b.height_spec.should eq 3
  ensure
    s.try &.destroy
  end
end

describe "Dim" do
  it "matches? accepts every property spelling; == stays structural" do
    d = Crysterm::Dim.percent(50)
    d.matches?("50%").should be_true
    d.matches?(Crysterm::Dim.percent(50)).should be_true
    d.matches?(50).should be_false
    d.matches?("not a dim").should be_false
    (d == Crysterm::Dim.percent(50)).should be_true
    Crysterm::Dim.cells(5).matches?(5).should be_true
    Crysterm::Dim.center.matches?(:center).should be_true
    Crysterm::Dim.auto.matches?(nil).should be_true
  end

  it "supports cell-offset arithmetic" do
    (Crysterm::Dim.percent(50) + 2).to_s.should eq "50%+2"
    (Crysterm::Dim.percent(100) - 2).to_s.should eq "100%-2"
    (Crysterm::Dim.cells(5) + 2).resolve(0).should eq 7
    (Crysterm::Dim.vw(50) + 2).to_s.should eq "50vw+2"
    Crysterm::Dim.parse("50vw+2").resolve_viewport(100, 40).should eq 52
    expect_raises(ArgumentError) { Crysterm::Dim.auto + 1 }
  end

  it "expresses auto and normalizes it to nil at assignment" do
    Crysterm::Dim.auto.auto?.should be_true
    Crysterm::Dim.from(Crysterm::Dim.auto).should be_nil
    Crysterm::Dim.from("auto").should be_nil
    Crysterm::Dim.auto.to_s.should eq "auto"
    expect_raises(ArgumentError) { Crysterm::Dim.auto.resolve(10) }
  end
end

describe "geometry value objects" do
  it "Rectangle exposes exclusive x_end/y_end" do
    r = Rectangle.new 2, 3, 10, 4
    r.x_end.should eq 12
    r.y_end.should eq 7
    r.responds_to?(:right).should be_false
    Crysterm::Rect.new(0, 0, 1, 1).width.should eq 1 # alias
  end

  it "Size and Point carry arithmetic" do
    (Size.new(3, 4) + Size.new(1, 1)).should eq Size.new(4, 5)
    (Size.new(3, 4) - Size.new(1, 1)).should eq Size.new(2, 3)
    (Size.new(3, 4) * 2).should eq Size.new(6, 8)
    Size.new(3, 4).transposed.should eq Size.new(4, 3)
    (Point.new(1, 2) * 3).should eq Point.new(3, 6)
  end

  it "painted_rect returns a Rectangle" do
    s = headless_screen(40, 10)
    b = Widget::Box.new parent: s, top: 2, left: 3, width: 10, height: 4
    s.repaint
    r = b.painted_rect
    r.should eq Rectangle.new(3, 2, 10, 4)
  ensure
    s.try &.destroy
  end

  it "region APIs take Rectangle and Point overloads" do
    s = headless_screen(20, 6)
    Widget::Box.new parent: s, top: 1, left: 1, width: 5, height: 2
    s.repaint
    s.fill_region s.default_attr, 'x', Rectangle.new(0, 0, 3, 1)
    s.cell_rows[0][2].char.should eq 'x'
    s.cell_rows[0][3].char.should_not eq 'x'
    p = s.widget_at(Point.new(2, 2))
    q = s.widget_at(2, 2)
    (p.nil? ? q.nil? : p.same?(q)).should be_true # Point ≡ scalar overload
    s.dump(Rectangle.new(0, 0, 3, 1)).try(&.includes?("xxx")).should be_true
  ensure
    s.try &.destroy
  end
end

describe "Layout::Dock hint size and DockWidget areas" do
  it "Hint#size overrides the child's own extent on the consume axis" do
    s = headless_screen(40, 10)
    c = Widget::Box.new parent: s, top: 0, left: 0, width: 40, height: 10,
      layout: Layout::Dock.new
    edge = Widget::Box.new parent: c, width: 30,
      layout_hint: Layout::Dock::Hint.new(:left, size: 10)
    center = Widget::Box.new parent: c
    s.repaint

    rect_of(edge)[2].should eq 10
    rect_of(center)[0].should eq 10
  ensure
    s.try &.destroy
  end

  it "rejects a Center dock area" do
    dock = Widget::DockWidget.new title: "D"
    expect_raises(ArgumentError) { dock.area = Widget::DockWidget::Area::Center }
  end
end

describe "MainWindow carve engine" do
  it "lays out bars, docks and central widget through Layout::Dock" do
    s = headless_screen(80, 24)
    win = Widget::MainWindow.new parent: s
    win.menu_bar # auto-vivifies
    win.status_bar.show_message "Ready"
    dock = Widget::DockWidget.new title: "P", area: :left, dock_size: 20
    win.add_dock dock
    win.central_widget = (cw = Widget::Box.new)
    s.repaint

    win.layout.not_nil!.is_a?(Widget::MainWindow::Carve).should be_true
    rect_of(win.menu_bar)[1].should eq 0
    rect_of(win.menu_bar)[2].should eq 80
    rect_of(win.status_bar)[1].should eq 23
    dx, dy, dw, dh = rect_of dock
    {dx, dy, dw, dh}.should eq({0, 1, 20, 22}) # spans between the bars
    cx, cy, cw2, ch = rect_of cw
    {cx, cy, cw2, ch}.should eq({20, 1, 60, 22})
  ensure
    s.try &.destroy
  end

  it "hides a bar's strip when it hides" do
    s = headless_screen(80, 24)
    win = Widget::MainWindow.new parent: s
    win.menu_bar
    win.central_widget = (cw = Widget::Box.new)
    s.repaint
    rect_of(cw)[1].should eq 1

    win.menu_bar.hide
    s.repaint
    rect_of(cw)[1].should eq 0 # vacancy: the strip is given back
  ensure
    s.try &.destroy
  end
end
