require "./spec_helper"

include Crysterm

# `margin` shifts (and shrinks) where a widget is PAINTED — `_get_coords`/`lpos`
# carries the inset (see margin_spec.cr). The geometry getters (`atop`/`aleft`/
# `awidth`/`aheight`) feed hit-testing (`Screen#widget_at`, `Widget#contains_point?`),
# so they must report the SAME rectangle the widget is drawn at; otherwise a
# margined widget — or any child of a margined container, whose position is built
# on the parent's `atop`/`aleft` — is clickable a row/column off from where it
# appears, and clicks miss it. (This was the qtmodern `QGroupBox { margin-top }`
# combo-dropdown bug: the group box's children were painted a row below their hit
# rectangle, so clicking the visible combo hit the group box behind it.)

private def mht_screen
  Crysterm::Screen.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 60, height: 24, default_quit_keys: false)
end

describe "margin hit-testing" do
  it "keeps a margined widget's hit rectangle equal to its rendered rectangle" do
    {0, 1, 2}.each do |m|
      s = mht_screen
      box = Widget::Box.new parent: s, top: 3, left: 2, width: 30, height: 10,
        style: Style.new(border: true, margin: Margin.new(m, m, m, m))
      s._render
      l = box.lpos.not_nil!
      # The getters used by hit-testing match the painted rectangle on every edge.
      box.aleft.should eq l.xi
      box.atop.should eq l.yi
      (box.aleft + box.awidth).should eq l.xl
      (box.atop + box.aheight).should eq l.yl
    end
  end

  it "places a child of a margined container at its painted position" do
    s = mht_screen
    # A group-box-like container with a top margin (the qtmodern case) and a child.
    gb = Widget::Box.new parent: s, top: 1, left: 1, width: 30, height: 12,
      style: Style.new(border: true, margin: Margin.new(0, 2, 0, 0))
    child = Widget::Box.new parent: gb, top: 4, left: 2, width: 10, height: 1
    s._render
    cl = child.lpos.not_nil!
    # The child carries no margin of its own, but inherits the parent's downward
    # shift through `gb.atop` — so its hit rectangle lands where it is painted.
    child.atop.should eq cl.yi
    child.aleft.should eq cl.xi
  end

  it "returns the right widget from widget_at over a margined container's child" do
    s = mht_screen
    gb = Widget::Box.new parent: s, top: 1, left: 1, width: 30, height: 12,
      style: Style.new(border: true, margin: Margin.new(0, 2, 0, 0))
    # A clickable child (a Click handler makes it mouse-responsive / hit-testable).
    child = Widget::Box.new parent: gb, top: 4, left: 2, width: 10, height: 1
    child.on(Crysterm::Event::Click) { }
    s._render
    # Hit-test at the child's PAINTED top-left: it must resolve to the child, not
    # the container painted behind it.
    cl = child.lpos.not_nil!
    s.widget_at(cl.xi, cl.yi).should eq child
  end
end
