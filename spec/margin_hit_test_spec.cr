require "./spec_helper"

include Crysterm

# `margin` shifts (and shrinks) where a widget is PAINTED — `coords`/`lpos`
# carries the inset (see margin_spec.cr). Hit-testing (`Window#widget_at`,
# `Widget#contains_point?`) must resolve to the rectangle the widget is actually
# DRAWN at; otherwise a margined widget, or a child of a margined container
# (built on the parent's `atop`/`aleft`), is clickable a row/column off from
# where it appears. (This was the qtmodern `QGroupBox { margin-top }` bug:
# children painted a row below their hit rectangle, so clicking the visible combo
# hit the group box behind it.)
#
# Hit-testing tests against the painted rectangle (`lpos`) rather than recomputing
# raw `aleft/atop/awidth/aheight`, because `lpos` also carries the enclosing-scroll
# offset and clipping — and for a `shrink_to_fit` (shrink-to-content) widget the raw
# `awidth`/`aheight` report the full parent slot, not the shrunk content box. The
# specs below assert both the simple margin equality and those two harder cases.

private def mht_screen
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 60, height: 24, default_quit_keys: false)
end

describe "margin hit-testing" do
  it "keeps a margined widget's hit rectangle equal to its rendered rectangle" do
    {0, 1, 2}.each do |m|
      s = mht_screen
      box = Widget::Box.new parent: s, top: 3, left: 2, width: 30, height: 10,
        style: Style.new(border: true, margin: Margin.new(m, m, m, m))
      s.repaint
      l = box.lpos.not_nil!
      # Hit-testing getters match the painted rectangle on every edge.
      box.aleft.should eq l.xi
      box.atop.should eq l.yi
      (box.aleft + box.awidth).should eq l.xl
      (box.atop + box.aheight).should eq l.yl
    end
  end

  it "places a child of a margined container at its painted position" do
    s = mht_screen
    # Group-box-like container with a top margin (the qtmodern case) and a child.
    gb = Widget::Box.new parent: s, top: 1, left: 1, width: 30, height: 12,
      style: Style.new(border: true, margin: Margin.new(0, 2, 0, 0))
    child = Widget::Box.new parent: gb, top: 4, left: 2, width: 10, height: 1
    s.repaint
    cl = child.lpos.not_nil!
    # Child has no margin of its own but inherits the parent's downward shift
    # through `gb.atop`, so its hit rectangle lands where it is painted.
    child.atop.should eq cl.yi
    child.aleft.should eq cl.xi
  end

  it "returns the right widget from widget_at over a margined container's child" do
    s = mht_screen
    gb = Widget::Box.new parent: s, top: 1, left: 1, width: 30, height: 12,
      style: Style.new(border: true, margin: Margin.new(0, 2, 0, 0))
    # Click handler makes the child mouse-responsive / hit-testable.
    child = Widget::Box.new parent: gb, top: 4, left: 2, width: 10, height: 1
    child.on(Crysterm::Event::Click) { }
    s.repaint
    # Hit-test at the child's painted top-left must resolve to the child, not
    # the container painted behind it.
    cl = child.lpos.not_nil!
    s.widget_at(cl.xi, cl.yi).should eq child
  end

  it "keeps a right/bottom-anchored margined widget's hit rectangle at its paint" do
    s = mht_screen
    # Right- and bottom-anchored: the NEAR margins are right/bottom, so the box
    # is pushed inward from those edges. Getter geometry must still equal `lpos`.
    box = Widget::Box.new parent: s, right: 2, bottom: 3, width: 10, height: 4,
      style: Style.new(margin: Margin.new(left: 1, top: 1, right: 2, bottom: 3))
    box.on(Crysterm::Event::Click) { }
    s.repaint
    l = box.lpos.not_nil!
    box.aleft.should eq l.xi
    box.atop.should eq l.yi
    (box.aleft + box.awidth).should eq l.xl
    (box.atop + box.aheight).should eq l.yl
    s.widget_at(l.xi, l.yi).should eq box
  end

  it "keeps a centered margined widget's hit rectangle at its paint" do
    s = mht_screen
    box = Widget::Box.new parent: s, top: "center", left: "center", width: 10, height: 4,
      style: Style.new(margin: 1)
    box.on(Crysterm::Event::Click) { }
    s.repaint
    l = box.lpos.not_nil!
    box.aleft.should eq l.xi
    box.atop.should eq l.yi
    (box.aleft + box.awidth).should eq l.xl
    (box.atop + box.aheight).should eq l.yl
    s.widget_at(l.xi, l.yi).should eq box
  end

  it "hit-tests a shrink_to_fit margined widget by its painted content box, not its slot" do
    s = mht_screen
    # A shrink-to-content widget in a wide slot: `awidth`/`aheight` report the
    # full slot, but it PAINTS only the 5x1 content box (shifted by margin 1).
    # Hit-testing must follow the painted box.
    box = Widget::Box.new parent: s, top: 2, left: 3, content: "hello",
      style: Style.new(margin: 1)
    box.shrink_to_fit = true
    box.on(Crysterm::Event::Click) { }
    s.repaint
    l = box.lpos.not_nil!
    # Inside the painted content box → the widget.
    s.widget_at(l.xi, l.yi).should eq box
    s.widget_at(l.xl - 1, l.yi).should eq box
    # A cell past the painted content but still inside the raw full-slot rectangle
    # must NOT resolve to it (the old raw-geometry bug).
    (l.xl < 40).should be_true
    s.widget_at(l.xl + 5, l.yi).should_not eq box
  end
end

# Hit-testing follows the painted rectangle, which carries the enclosing-scroll
# offset and clipping: an item scrolled out of a viewport is not clickable, and a
# scrolled-in one is clickable where it lands, not at its unscrolled coordinates.
describe "scroll/clip hit-testing" do
  it "does not hit a child scrolled out of its container's viewport" do
    s = mht_screen
    c = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 5, scrollable: true
    # Child below the 5-row viewport → painted nothing (`lpos == nil`).
    child = Widget::Box.new parent: c, top: 10, left: 0, width: 10, height: 1, content: "x"
    child.on(Crysterm::Event::Click) { }
    s.repaint
    child.lpos.should be_nil
    # Its unscrolled coordinates must not be clickable while it is off-screen.
    s.widget_at(0, 10).should_not eq child
  end

  it "hits a scrolled-in child at its painted position, not its unscrolled one" do
    s = mht_screen
    c = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 5, scrollable: true
    child = Widget::Box.new parent: c, top: 10, left: 0, width: 10, height: 1, content: "x"
    child.on(Crysterm::Event::Click) { }
    s.repaint
    c.scroll_to 10
    s.repaint
    cl = child.lpos.not_nil!
    # Now visible inside the viewport (rows 0..4), well above its `top: 10`.
    (cl.yi < 10).should be_true
    s.widget_at(cl.xi, cl.yi).should eq child
    # The old unscrolled row must no longer hit it.
    s.widget_at(0, 10).should_not eq child
  end
end
