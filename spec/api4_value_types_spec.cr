require "./spec_helper"

include Crysterm

# Coverage for the API4 mechanical value-type/layout convenience additions
# (Deferred → Fable, Area 2 A4-11..A4-21 and Area 3 A4-23..A4-33). Each block
# maps to an A4-* finding; see plans/API4.md.

describe "API4 value-type / layout additions" do
  describe "Widget#pos / #size / #rect (A4-11)" do
    it "pos bundles (x, y)" do
      s = headless_screen(40, 20)
      w = Widget::Box.new parent: s, left: 2, top: 3, width: 5, height: 4
      w.pos.should eq Point.new(w.x, w.y)
    end

    it "size bundles (awidth, aheight)" do
      s = headless_screen(40, 20)
      w = Widget::Box.new parent: s, left: 2, top: 3, width: 5, height: 4
      w.awidth.should eq 5
      w.aheight.should eq 4
      w.size.should eq Size.new(5, 4)
    end

    it "rect is (0, 0, awidth, aheight)" do
      s = headless_screen(40, 20)
      w = Widget::Box.new parent: s, left: 2, top: 3, width: 5, height: 4
      w.rect.should eq Rectangle.new(0, 0, 5, 4)
    end
  end

  describe "Widget#move/#resize Point/Size overloads + #pos=/#size= (A4-12)" do
    it "move(Point) and pos= delegate to the Int32 form" do
      s = headless_screen(40, 20)
      w = Widget::Box.new parent: s, left: 0, top: 0, width: 5, height: 4
      w.move Point.new(2, 3)
      w.left.should eq 2
      w.top.should eq 3
      w.pos = Point.new(6, 7)
      w.left.should eq 6
      w.top.should eq 7
    end

    it "resize(Size) and size= delegate to the Int32 form" do
      s = headless_screen(40, 20)
      w = Widget::Box.new parent: s, width: 5, height: 4
      w.resize Size.new(8, 9)
      w.width.should eq 8
      w.height.should eq 9
      w.size = Size.new(10, 11)
      w.width.should eq 10
      w.height.should eq 11
    end
  end

  describe "Widget#geometry= (A4-13)" do
    it "delegates to #set_geometry(Rectangle)" do
      s = headless_screen(40, 20)
      w = Widget::Box.new parent: s, left: 0, top: 0, width: 1, height: 1
      w.geometry = Rectangle.new(3, 4, 6, 7)
      w.left.should eq 3
      w.top.should eq 4
      w.width.should eq 6
      w.height.should eq 7
    end
  end

  describe "Widget#minimum_size/#maximum_size (A4-14)" do
    it "the reader is nil when only one half of the pair is set" do
      s = headless_screen(40, 20)
      w = Widget::Box.new parent: s
      w.min_width = 3
      w.minimum_size.should be_nil
      w.min_height = 5
      w.minimum_size.should eq Size.new(3, 5)
    end

    it "the setter assigns both halves; nil clears both" do
      s = headless_screen(40, 20)
      w = Widget::Box.new parent: s
      w.minimum_size = Size.new(2, 3)
      w.min_width.should eq 2
      w.min_height.should eq 3
      w.maximum_size = Size.new(20, 30)
      w.max_width.should eq 20
      w.max_height.should eq 30
      w.minimum_size = nil
      w.min_width.should be_nil
      w.min_height.should be_nil
    end
  end

  describe "Widget#lower / #stack_under (A4-15)" do
    it "lower is an alias of to_back" do
      s = headless_screen(40, 20)
      parent = Widget::Box.new parent: s, width: 20, height: 10
      Widget::Box.new parent: parent
      Widget::Box.new parent: parent
      c = Widget::Box.new parent: parent
      c.lower
      parent.children.first.should be c
    end

    it "stack_under sets stack_index to the sibling's" do
      s = headless_screen(40, 20)
      parent = Widget::Box.new parent: s, width: 20, height: 10
      a = Widget::Box.new parent: parent
      b = Widget::Box.new parent: parent
      c = Widget::Box.new parent: parent
      b.stack_under(c)
      parent.children.should eq [a, c, b]
    end

    it "is a no-op for an unattached sibling" do
      s = headless_screen(40, 20)
      parent = Widget::Box.new parent: s, width: 20, height: 10
      a = Widget::Box.new parent: parent
      b = Widget::Box.new parent: parent
      detached = Widget::Box.new
      a.stack_under(detached)
      parent.children.should eq [a, b]
    end
  end

  describe "Widget#frame_geometry (A4-17)" do
    it "aliases #geometry" do
      s = headless_screen(40, 20)
      w = Widget::Box.new parent: s, left: 1, top: 1, width: 5, height: 3
      s.repaint
      w.frame_geometry.should_not be_nil
      w.frame_geometry.should eq w.geometry
    end
  end

  describe "Widget#label_side / #label_side= (A4-21)" do
    it "reads the side #set_label placed the label on" do
      s = headless_screen(40, 20)
      w = Widget::Box.new parent: s, width: 10, height: 3
      w.set_label "Name", :right
      w.label_side.should eq Widget::LabelSide::Right
    end

    it "moves an existing label and re-runs placement" do
      s = headless_screen(40, 20)
      w = Widget::Box.new parent: s, width: 10, height: 3
      w.set_label "Name", :left
      w.label_side = Widget::LabelSide::Right
      w.label_side.should eq Widget::LabelSide::Right
      lbl = w.label_widget.not_nil!
      lbl.left.should be_nil
      lbl.right.should_not be_nil
    end

    it "remembers the side for a label set afterward, when none exists yet" do
      s = headless_screen(40, 20)
      w = Widget::Box.new parent: s, width: 10, height: 3
      w.label_side = Widget::LabelSide::Right
      w.label = "Name"
      w.label_side.should eq Widget::LabelSide::Right
      lbl = w.label_widget.not_nil!
      lbl.left.should be_nil
      lbl.right.should_not be_nil
    end
  end

  describe "Rectangle #adjusted / #move_to / #with_size / .new(top_left, ...) (A4-23, A4-33)" do
    it "adjusted nudges each edge independently, respecting the exclusive right/bottom" do
      r = Rectangle.new(5, 5, 10, 4) # xi=5 xl=15 yi=5 yl=9
      r.adjusted(1, 1, -1, -1).should eq Rectangle.of_edges(6, 6, 14, 8)
    end

    it "move_to repositions the top-left, keeping size" do
      r = Rectangle.new(5, 5, 10, 4)
      r.move_to(0, 0).should eq Rectangle.new(0, 0, 10, 4)
      r.move_to(Point.new(2, 3)).should eq Rectangle.new(2, 3, 10, 4)
    end

    it "with_size replaces the extent, keeping the top-left" do
      r = Rectangle.new(5, 5, 10, 4)
      r.with_size(20, 1).should eq Rectangle.new(5, 5, 20, 1)
      r.with_size(Size.new(20, 1)).should eq Rectangle.new(5, 5, 20, 1)
    end

    it ".new(top_left, size) matches the x/y/width/height constructor" do
      Rectangle.new(Point.new(1, 2), Size.new(3, 4)).should eq Rectangle.new(1, 2, 3, 4)
    end

    it ".new(top_left, bottom_right) uses the half-open exclusive corner" do
      r = Rectangle.new(Point.new(1, 2), Point.new(4, 6))
      r.should eq Rectangle.of_edges(1, 2, 4, 6)
      r.width.should eq 3
      r.height.should eq 4
    end

    it ".from_edges aliases .of_edges" do
      Rectangle.from_edges(1, 2, 4, 6).should eq Rectangle.of_edges(1, 2, 4, 6)
    end
  end

  describe "Rectangle#translated(Point) (A4-24)" do
    it "matches the two-arg form" do
      r = Rectangle.new(5, 5, 10, 4)
      r.translated(Point.new(1, 2)).should eq r.translated(1, 2)
    end
  end

  describe "Rectangle #+/#- (SidedGeometry) and SidedGeometry#inset/#outset (A4-25)" do
    it "+ grows by margins (outset), - shrinks (inset)" do
      r = Rectangle.new(10, 10, 20, 20) # xi=10 xl=30 yi=10 yl=30
      m = Margin.new(1, 2, 3, 4)        # LTRB: left=1 top=2 right=3 bottom=4

      grown = r + m
      grown.should eq Rectangle.of_edges(9, 8, 33, 34)
      m.outset(r).should eq grown

      shrunk = r - m
      shrunk.should eq Rectangle.of_edges(11, 12, 27, 26)
      m.inset(r).should eq shrunk
    end
  end

  describe "Point#+/#- and Size#empty?/#area/#bounded_to/#expanded_to (A4-26)" do
    it "Point arithmetic" do
      (Point.new(1, 2) + Point.new(3, 4)).should eq Point.new(4, 6)
      (Point.new(5, 5) - Point.new(2, 1)).should eq Point.new(3, 4)
    end

    it "Size#empty?" do
      Size.new(0, 5).empty?.should be_true
      Size.new(5, 0).empty?.should be_true
      Size.new(-1, 5).empty?.should be_true
      Size.new(5, 5).empty?.should be_false
    end

    it "Size#area" do
      Size.new(3, 4).area.should eq 12
    end

    it "Size#bounded_to / #expanded_to" do
      Size.new(10, 2).bounded_to(Size.new(5, 20)).should eq Size.new(5, 2)
      Size.new(10, 2).expanded_to(Size.new(5, 20)).should eq Size.new(10, 20)
    end
  end

  describe "RenderedGeometry accessor parity with Rectangle (A4-27)" do
    it "right/bottom/size/top_left/center/contains? share Rectangle's exclusive-edge semantics" do
      s = headless_screen(40, 20)
      w = Widget::Box.new parent: s, left: 2, top: 3, width: 5, height: 4
      s.repaint
      lp = w.lpos.not_nil!
      lp.right.should eq lp.xl
      lp.bottom.should eq lp.yl
      lp.size.should eq Size.new(lp.width, lp.height)
      lp.top_left.should eq Point.new(lp.xi, lp.yi)
      lp.center.should eq Point.new(lp.xi + lp.width // 2, lp.yi + lp.height // 2)
      lp.contains?(lp.xi, lp.yi).should be_true
      lp.contains?(lp.xl, lp.yl).should be_false # one-past-the-end, exclusive
    end
  end

  describe "Layout::Stack#current_widget= (A4-28)" do
    it "finds the arrangeable index and sets current_index" do
      s = headless_screen(40, 20)
      stack = Widget::Box.new parent: s, width: 10, height: 5, layout: Layout::Stack.new
      a = Widget::Box.new parent: stack
      Widget::Box.new parent: stack
      c = Widget::Box.new parent: stack
      lay = stack.layout.as(Layout::Stack)

      lay.current_widget = c
      lay.current_index.should eq 2
      lay.current_widget.should be c

      lay.current_widget = a
      lay.current_index.should eq 0
    end

    it "is a no-op for a widget that isn't an arrangeable child" do
      s = headless_screen(40, 20)
      stack = Widget::Box.new parent: s, width: 10, height: 5, layout: Layout::Stack.new
      Widget::Box.new parent: stack
      outsider = Widget::Box.new parent: s
      lay = stack.layout.as(Layout::Stack)

      lay.current_index = 0
      lay.current_widget = outsider
      lay.current_index.should eq 0
    end
  end

  describe "Layout::Form#add_row overloads (A4-29)" do
    it "add_row(String, Widget) pairs a fresh label Box with the field" do
      s = headless_screen(40, 20)
      form = Widget::Box.new parent: s, width: 40, height: 20, layout: Layout::Form.new
      field = Widget::Box.new height: 1
      lay = form.layout.as(Layout::Form)

      lay.add_row("Name", field).should be field
      form.children.size.should eq 2
      form.children[0].content.should eq "Name"
      form.children[1].should be field
    end

    it "add_row(Widget, Widget) pairs an already-built label widget" do
      s = headless_screen(40, 20)
      form = Widget::Box.new parent: s, width: 40, height: 20, layout: Layout::Form.new
      label = Widget::Box.new content: "Custom"
      field = Widget::Box.new height: 1
      lay = form.layout.as(Layout::Form)

      lay.add_row(label, field).should be field
      form.children.should eq [label, field]
    end

    it "add_row(Widget) spans the full row" do
      s = headless_screen(40, 20)
      form = Widget::Box.new parent: s, width: 40, height: 20, layout: Layout::Form.new
      btn = Widget::Box.new height: 1
      lay = form.layout.as(Layout::Form)

      lay.add_row(btn).should be btn
      form.children.should eq [btn]
    end

    it "inserts a new pair before an existing trailing full-span row" do
      s = headless_screen(40, 20)
      form = Widget::Box.new parent: s, width: 40, height: 20, layout: Layout::Form.new
      lay = form.layout.as(Layout::Form)

      trailing = Widget::Box.new height: 1
      lay.add_row(trailing)

      field = Widget::Box.new height: 1
      lay.add_row("Name", field)

      form.children.last.should be trailing
      form.children.index(trailing).should eq 2
    end
  end

  describe "Layout::Grid#add_widget / Grid::Hint.at (A4-31)" do
    it "add_widget appends w and sets its layout_hint" do
      s = headless_screen(40, 20)
      grid = Widget::Box.new parent: s, width: 40, height: 20, layout: Layout::Grid.new(columns: 3)
      w = Widget::Box.new height: 1
      lay = grid.layout.as(Layout::Grid)

      lay.add_widget(w, 1, 2, 2, 1).should be w
      grid.children.last.should be w

      hint = w.layout_hint.as(Layout::Grid::Hint)
      hint.row.should eq 1
      hint.column.should eq 2
      hint.row_span.should eq 2
      hint.column_span.should eq 1
    end

    it "Hint.at builds the same Hint as .new" do
      a = Layout::Grid::Hint.at(3, 4, 2, 5)
      b = Layout::Grid::Hint.new(3, 4, 2, 5)
      {a.row, a.column, a.row_span, a.column_span}.should eq({b.row, b.column, b.row_span, b.column_span})
    end
  end

  describe "Padding/Margin .ltrb/.trbl/.vh named constructors (A4-32)" do
    it ".ltrb matches the positional LTRB constructor" do
      a = Margin.ltrb(1, 2, 3, 4)
      b = Margin.new(1, 2, 3, 4)
      {a.left, a.top, a.right, a.bottom}.should eq({b.left, b.top, b.right, b.bottom})
    end

    it ".trbl spells the CSS clockwise-from-top order" do
      m = Margin.trbl(2, 3, 4, 1) # top right bottom left
      {m.left, m.top, m.right, m.bottom}.should eq({1, 2, 3, 4})
    end

    it ".vh spells the vertical/horizontal 2-value order" do
      m = Margin.vh(2, 5) # v h
      {m.left, m.top, m.right, m.bottom}.should eq({5, 2, 5, 2})
    end

    it "works identically for Padding" do
      p = Padding.ltrb(1, 1, 1, 1)
      {p.left, p.top, p.right, p.bottom}.should eq({1, 1, 1, 1})
    end
  end
end
