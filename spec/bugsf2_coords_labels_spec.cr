require "./spec_helper"

include Crysterm

# Regression coverage for BUGS-F2 findings 2, 14, 34, 48 — all "layout vs
# painted coordinate" bugs plus the scroll-clip label exemption.
#
#   2  (widget_position/widget_label/widget) scroll-clip exemption tested "HAS a
#      label" (`@label_widget`) instead of "IS a label" (`_is_label?`), so labels
#      vanished on scrollable widgets.
#  14  (mixin/check_marker) marker-click hit-test used layout coords, so a
#      checkbox/radio inside a scrolled container never toggled by mouse.
#  34  (mixin/track_geometry) vertical slider/progress-bar pointer offset used
#      layout coords, seeking wrong inside a scrolled container.
#  48  (widget_table_layout/table/listtable) internal cell separators hardcoded
#      a 1-column content inset instead of honoring `ileft`.

private def f2_screen(w = 80, h = 24)
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: w, height: h,
    default_quit_keys: false)
end

private def f2_down(s, x, y)
  s.dispatch_mouse(::Tput::Mouse::Event.new(
    ::Tput::Mouse::Action::Down, ::Tput::Mouse::Button::Left, x, y, source: :test))
end

private def f2_screen_text(s) : String
  String.build do |io|
    s.lines.each do |line|
      (0...s.awidth).each do |x|
        c = line[x]?.try(&.char) || ' '
        io << (c == '\0' ? ' ' : c)
      end
      io << '\n'
    end
  end
end

describe "BUGS-F2 finding 2: scroll-clip label exemption is 'IS a label'" do
  it "renders a label on a scrollable bordered box" do
    s = f2_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 8,
      scrollable: true, label: "TITLE", style: Style.new(border: true)
    s.repaint

    # The label child must be positioned (not clipped away) and painted.
    box.label_widget.should_not be_nil
    box.label_widget.not_nil!.lpos.should_not be_nil
    f2_screen_text(s).includes?("TITLE").should be_true
  end

  it "marks the label box as a label and leaves ordinary widgets unmarked" do
    s = f2_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 8,
      scrollable: true, label: "HDR", style: Style.new(border: true)
    box._is_label?.should be_false
    box.label_widget.not_nil!._is_label?.should be_true
  end

  it "does not let a labeled child overdraw a scrolled container's border" do
    s = f2_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 24, height: 6,
      scrollable: true, style: Style.new(border: true)
    # A labeled child taller than the viewport, forcing a scroll.
    Widget::Box.new parent: box, top: 0, left: 0, width: 10, height: 20,
      label: "CH", style: Style.new(border: true)
    s.repaint
    box.scroll 10
    s.repaint

    # The container's own bottom-left corner must survive (not be punched
    # through by the scrolled child's border). Before the fix all four clip
    # compensations were zeroed for the labeled child, corrupting the frame.
    bl = box.lpos.not_nil!
    corner = s.lines[bl.yl - 1][bl.xi]?.try(&.char)
    corner.should eq '└'
  end
end

describe "BUGS-F2 finding 14: CheckMarker marker-click uses painted coords" do
  it "toggles a checkbox inside a scrolled container" do
    s = f2_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 30, height: 5,
      scrollable: true
    boxes = (0...12).map do |i|
      Widget::CheckBox.new parent: box, top: i, left: 0, width: 20, height: 1,
        content: "Opt#{i}"
    end
    s.repaint
    box.scroll 4
    s.repaint

    # Pick a checkbox that is now painted inside the viewport.
    target = boxes.find!(&.lpos)
    lp = target.lpos.not_nil!
    target.checked?.should be_false

    # Click the marker glyph at its PAINTED position.
    f2_down s, lp.xi + 1, lp.yi
    target.checked?.should be_true
  end
end

describe "BUGS-F2 finding 34: TrackGeometry vertical offset uses painted coords" do
  it "seeks a vertical slider correctly inside a scrolled container" do
    s = f2_screen(30, 24)
    # Text content gives a reliable vertical scroll extent (`scroll_height`
    # uses `@_clines.size`); the slider is a child that moves with the scroll.
    content = (0...30).map { |i| "line#{i}" }.join("\n")
    box = Widget::ScrollableBox.new parent: s, top: 0, left: 0, width: 20,
      height: 12, scrollbar: false, content: content
    sl = Widget::Slider.new parent: box, top: 15, left: 0, width: 3, height: 8,
      orientation: Tput::Orientation::Vertical, minimum: 0, maximum: 100, value: 0
    s.repaint
    box.scroll_to 14, true
    s.repaint

    # The slider's layout top (15) differs from its painted top (15 - 14 == 1);
    # every click must be resolved against the painted `@lpos`.
    lp = sl.lpos.not_nil!
    lp.yi.should_not eq sl.atop
    span = sl.aheight - sl.ivertical - 1 # == 7

    # Painted TOP row: a vertical slider fills bottom->top, so the top is max.
    f2_down s, lp.xi + 1, lp.yi
    sl.value.should eq 100

    # Painted BOTTOM row: the low end == minimum. With the old layout-coord
    # formula the scroll base drove `pos` negative and `invert` clamped this to
    # 100 as well — the discriminating assertion.
    sl.value = 50
    f2_down s, lp.xi + 1, lp.yi + span
    sl.value.should eq 0
  end
end

describe "BUGS-F2 finding 48: table separators honor ileft, not a hardcoded 1" do
  it "still renders a plain bordered table's separators (ileft == 1)" do
    s = f2_screen
    t = Widget::Table.new parent: s, top: 0, left: 0,
      rows: [["AA", "BB"], ["CC", "DD"]],
      style: Style.new(border: true)
    s.repaint

    t.ileft.should eq 1
    # A vertical separator sits at content offset maxes[0] from the content
    # origin (aleft + ileft).
    sep_x = t.aleft + t.ileft + t.@maxes[0]
    txt = f2_screen_text s
    lines = txt.split('\n')
    # Some interior row carries a '│' (or junction) at the separator column.
    found = (t.atop...(t.atop + t.aheight)).any? do |y|
      ch = lines[y]?.try(&.[sep_x]?)
      ch == '│' || ch == '┼' || ch == '┬' || ch == '┴'
    end
    found.should be_true
  end

  it "shifts the separator right by the left inset when the table is padded" do
    s = f2_screen
    t = Widget::Table.new parent: s, top: 0, left: 0,
      rows: [["AA", "BB"], ["CC", "DD"]],
      style: Style.new(border: true, padding: Padding.new(2, 0, 0, 0)) # left: 2
    s.repaint

    t.ileft.should eq 3 # border 1 + padding 2
    sep_x = t.aleft + t.ileft + t.@maxes[0]
    # The buggy position (hardcoded ileft == 1) would be two cells to the left.
    buggy_x = t.aleft + 1 + t.@maxes[0]

    txt = f2_screen_text s
    lines = txt.split('\n')
    sep_char = ->(x : Int32) do
      (t.atop...(t.atop + t.aheight)).any? do |y|
        ch = lines[y]?.try(&.[x]?)
        ch == '│' || ch == '┼' || ch == '┬' || ch == '┴'
      end
    end
    sep_char.call(sep_x).should be_true
    sep_char.call(buggy_x).should be_false
  end
end
