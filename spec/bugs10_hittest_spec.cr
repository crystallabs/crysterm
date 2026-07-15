require "./spec_helper"

include Crysterm

# BUGS10 #16: ScrollBar's mouse seek/drag mapped the pointer with layout coords
# (`atop`/`aleft`), while mouse events are dispatched by *painted* geometry
# (`lpos`), which inside a scrolled container is shifted by the ancestor's
# scroll base — so the thumb sought N rows above the click. Same defect class
# as `Mixin::TrackGeometry#pointer_offset` / `Mixin::CheckMarker`.
#
# BUGS10 #24: `Layout#render_children` returned early when the container's
# interior collapsed to nothing, leaving the children's (and their subtrees')
# last-rendered `lpos` intact — so `Window#widget_at` kept hitting them at
# stale positions from the previous frame.

private def b10_screen
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 60, height: 24, default_quit_keys: false)
end

private def b10_mouse(action, x, y, button = ::Tput::Mouse::Button::Left)
  Crysterm::Event::Mouse.new(::Tput::Mouse::Event.new(action, button, x, y, source: :test))
end

# A scrolled ancestor shifts where children are PAINTED (`lpos` folds in the
# ancestor's `child_base`) without changing their layout coords (`atop`). The
# bar is fully visible after the scroll here; the partially-clipped case
# (painted track compressed into the clipped rect) is covered separately below.
private def b10_scrolled_bar
  s = b10_screen
  outer = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 6, scrollable: true
  # Tall spacer so the container has plenty to scroll (`child_base` moves only
  # once the offset exceeds the viewport).
  Widget::Box.new parent: outer, top: 0, left: 5, width: 1, height: 30
  bar = Widget::ScrollBar.new parent: outer, top: 8, left: 0, width: 1, height: 5,
    minimum: 0, maximum: 4
  s._render
  outer.scroll_to 12
  s._render
  base = outer.child_base
  base.should be > 0
  lp = bar.lpos.not_nil!
  # Painted `base` rows above the layout position, and fully visible.
  lp.yi.should eq bar.atop - base
  (lp.yl - lp.yi).should eq 5
  {s, bar, lp}
end

describe "BUGS10 16: ScrollBar pointer mapping uses painted coords" do
  it "seeks to the clicked cell when unscrolled (control)" do
    s = b10_screen
    bar = Widget::ScrollBar.new parent: s, top: 4, left: 0, width: 1, height: 10,
      minimum: 0, maximum: 9
    s._render
    # Painted position equals layout position here; click 5 cells into the bar.
    bar.emit Crysterm::Event::Mouse, b10_mouse(::Tput::Mouse::Action::Down, 0, 4 + 5).mouse
    bar.slider_position.should eq 5
  end

  it "seeks to the clicked cell inside a scrolled container" do
    s, bar, lp = b10_scrolled_bar
    # Dispatch resolves by painted geometry: the painted cell belongs to the bar.
    s.widget_at(lp.xi, lp.yi + 3).should eq bar
    # Click 3 cells into the *painted* bar. With layout-coord mapping raw came
    # out `base` rows smaller (clamped to 0) and the thumb sought above the click.
    bar.emit Crysterm::Event::Mouse, b10_mouse(::Tput::Mouse::Action::Down, lp.xi, lp.yi + 3).mouse
    bar.slider_position.should eq 3
  end

  it "maps a drag (move with button held) by painted coords too" do
    _, bar, lp = b10_scrolled_bar
    bar.emit Crysterm::Event::Mouse, b10_mouse(::Tput::Mouse::Action::Down, lp.xi, lp.yi + 1).mouse
    bar.slider_position.should eq 1
    bar.emit Crysterm::Event::Mouse, b10_mouse(::Tput::Mouse::Action::Move, lp.xi, lp.yi + 2).mouse
    bar.slider_position.should eq 2
  end
end

describe "BUGS10 16 follow-up: clipped ScrollBar seeks over the painted track" do
  # `ScrollBar#render` paints the whole track compressed into the clipped rect
  # (`with_inner_coords` works from the border-adjusted `@lpos`), so the seek
  # math must use that same painted span — the layout-size span (`aheight -
  # ivertical`) made clicks on a clipped bar land proportionally short.
  it "seeking the last painted track cell reaches the maximum" do
    s = b10_screen
    outer = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 6, scrollable: true
    Widget::Box.new parent: outer, top: 0, left: 5, width: 1, height: 30
    bar = Widget::ScrollBar.new parent: outer, top: 8, left: 0, width: 1, height: 5,
      minimum: 0, maximum: 4
    s._render
    outer.scroll_to 16
    s._render
    # Setup guard: the bar must straddle the viewport top — partially clipped,
    # at least 2 painted rows (so the trough has a non-degenerate span).
    clip = outer.child_base - 8
    clip.should be > 0
    clip.should be < 4
    lp = bar.lpos.not_nil!
    inner = lp.yl - lp.yi
    inner.should eq 5 - clip
    # The painted track is the WHOLE value range compressed into `inner` cells:
    # its last cell must seek to `maximum`.
    bar.emit Crysterm::Event::Mouse, b10_mouse(::Tput::Mouse::Action::Down, lp.xi, lp.yi + (inner - 1)).mouse
    bar.slider_position.should eq 4
    # And its first cell back to `minimum`.
    bar.emit Crysterm::Event::Mouse, b10_mouse(::Tput::Mouse::Action::Down, lp.xi, lp.yi).mouse
    bar.slider_position.should eq 0
  end
end

# Flow overflow harness for the subtree-skip examples: three 28×4 children in
# a 30-wide `Wrap` (one per row), grandchildren under the 2nd and 3rd, then
# shrunk so the second row overflows the interior.
private def b10_flow_box(overflow)
  s = b10_screen
  box = Widget::Box.new parent: s, top: 0, left: 0, width: 30, height: 12,
    layout: Layout::Wrap.new
  box.overflow = overflow
  Widget::Box.new parent: box, width: 28, height: 4
  b = Widget::Box.new parent: box, width: 28, height: 4
  bg = Widget::Box.new parent: b, top: 1, left: 1, width: 5, height: 1
  c = Widget::Box.new parent: box, width: 28, height: 4
  cg = Widget::Box.new parent: c, top: 1, left: 1, width: 5, height: 1
  s._render
  bg.lpos.should_not be_nil
  cg.lpos.should_not be_nil
  # Shrink so the second row (`b`) overflows the interior.
  box.height = 6
  s._render
  {b, bg, c, cg}
end

describe "BUGS10 24 follow-up: Flow skip branches clear whole subtrees" do
  # `Flow#arrange`'s `SkipWidget`/`StopRendering` branches shallow-skipped: the
  # skipped child's `lpos` cleared but its descendants kept last frame's rects,
  # staying clickable (`widget_at` hit-tests every widget independently).
  it "StopRendering clears the stopping child's and the unplaced children's subtrees" do
    b, bg, c, cg = b10_flow_box Crysterm::Overflow::StopRendering
    b.lpos.should be_nil
    bg.lpos.should be_nil
    c.lpos.should be_nil
    cg.lpos.should be_nil
  end

  it "SkipWidget clears each skipped child's subtree" do
    b, bg, _, cg = b10_flow_box Crysterm::Overflow::SkipWidget
    b.lpos.should be_nil
    bg.lpos.should be_nil
    # `c` wraps to the same overflowing row (chains off the last *rendered*
    # child) and is skipped too — its subtree must clear as well.
    cg.lpos.should be_nil
  end
end

describe "BUGS10 24: collapsed container interior clears children's hit rects" do
  it "makes a child unclickable when the interior collapses" do
    s = b10_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 10,
      layout: Layout::VBox.new, style: Style.new(border: true)
    child = Widget::Box.new parent: box, width: 10, height: 3
    child.on(Crysterm::Event::Click) { }
    s._render
    cl = child.lpos.not_nil!
    s.widget_at(cl.xi + 1, cl.yi + 1).should eq child

    # Collapse the interior to 0 rows (border eats both remaining rows).
    box.height = 2
    s._render
    child.lpos.should be_nil
    s.widget_at(cl.xi + 1, cl.yi + 1).should_not eq child
  end

  it "clears grandchildren too (widget_at hit-tests every widget independently)" do
    s = b10_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 10,
      layout: Layout::VBox.new, style: Style.new(border: true)
    child = Widget::Box.new parent: box, width: 14, height: 5
    grand = Widget::Box.new parent: child, top: 1, left: 1, width: 6, height: 1
    grand.on(Crysterm::Event::Click) { }
    s._render
    gl = grand.lpos.not_nil!
    s.widget_at(gl.xi, gl.yi).should eq grand

    box.height = 2
    s._render
    grand.lpos.should be_nil
    s.widget_at(gl.xi, gl.yi).should_not eq grand
  end

  it "children render again when the interior re-expands" do
    s = b10_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 10,
      layout: Layout::VBox.new, style: Style.new(border: true)
    child = Widget::Box.new parent: box, width: 10, height: 3
    child.on(Crysterm::Event::Click) { }
    s._render
    box.height = 2
    s._render
    child.lpos.should be_nil

    box.height = 10
    s._render
    cl = child.lpos.not_nil!
    s.widget_at(cl.xi + 1, cl.yi + 1).should eq child
  end
end
