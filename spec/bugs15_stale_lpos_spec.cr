require "./spec_helper"

include Crysterm

# BUGS15 #25: `Widget#_render`'s early-return paths (nil `coords`, or a
# degenerate zero-width/height rect) cleared only the widget's OWN `lpos`,
# leaving every descendant's last-rendered rect intact. Because `Window#widget_at`
# hit-tests each widget independently against its own `lpos`, a scrolled-away
# grandchild kept stealing clicks/hovers at the previous frame's position — the
# same invariant `Layout#skip_subtree` and the Flow `StopRendering` fix enforce.

private def b15_screen
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 60, height: 24, default_quit_keys: false)
end

describe "BUGS15 25: early-return _render clears descendants' hit rects" do
  it "a scrolled-away descendant is no longer hit-testable" do
    s = b15_screen
    # Manual placement (the default) scrollable container.
    outer = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 6, scrollable: true
    # Tall spacer so the container has plenty to scroll past the viewport.
    Widget::Box.new parent: outer, top: 6, left: 0, width: 1, height: 40
    # Box W at the very top, holding a clickable grandchild G.
    w = Widget::Box.new parent: outer, top: 0, left: 0, width: 18, height: 4
    g = Widget::Box.new parent: w, top: 1, left: 1, width: 6, height: 1
    g.on(Crysterm::Event::Click) { }

    s._render
    gl = g.lpos.not_nil!
    # Frame 1: G paints and is hit-testable at its on-screen rect.
    s.widget_at(gl.xi, gl.yi).should eq g

    # Scroll so W (rows 0..4) moves entirely above the viewport: `coords`
    # returns nil for W, which early-returns from `_render` before rendering G.
    outer.scroll_to 20
    s._render
    outer.child_base.should be > 4
    w.lpos.should be_nil

    # The fix: G's stale rect must be cleared, so it no longer steals the click.
    g.lpos.should be_nil
    s.widget_at(gl.xi, gl.yi).should_not eq g
  end

  it "descendants render again when scrolled back into view" do
    s = b15_screen
    outer = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 6, scrollable: true
    Widget::Box.new parent: outer, top: 6, left: 0, width: 1, height: 40
    w = Widget::Box.new parent: outer, top: 0, left: 0, width: 18, height: 4
    g = Widget::Box.new parent: w, top: 1, left: 1, width: 6, height: 1
    g.on(Crysterm::Event::Click) { }

    s._render
    outer.scroll_to 20
    s._render
    g.lpos.should be_nil

    outer.scroll_to 0
    s._render
    gl = g.lpos.not_nil!
    s.widget_at(gl.xi, gl.yi).should eq g
  end

  it "a degenerate zero-height container clears its descendants' hit rects" do
    s = b15_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 5
    grand = Widget::Box.new parent: box, top: 1, left: 1, width: 6, height: 1
    grand.on(Crysterm::Event::Click) { }
    s._render
    gl = grand.lpos.not_nil!
    s.widget_at(gl.xi, gl.yi).should eq grand

    # Collapse the container to zero rows: `_render` hits the degenerate-height
    # early return, which must still clear the descendant's stale rect.
    box.height = 0
    s._render
    grand.lpos.should be_nil
    s.widget_at(gl.xi, gl.yi).should_not eq grand
  end
end
