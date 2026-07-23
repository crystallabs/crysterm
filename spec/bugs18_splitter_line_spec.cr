require "./spec_helper"

include Crysterm

# Regression specs for BUGS18 B18-51, B18-52 and B18-55.
#
# B18-51: flipping a `Splitter`'s orientation at runtime left every non-last
# pane with the size the OLD axis had pinned (an explicit Int32 `width`/
# `height` wins over the freshly-set `left: 0`/`right: 0` stretch), so panes
# rendered at their old extents instead of spanning the splitter. The bare
# `property orientation` also scheduled no relayout/repaint. `place_pane` now
# clears the cross-axis size and the setter is change-guarded.
#
# B18-52: `Line#orientation=` copied the length onto the new axis but never
# cleared the old one, leaving BOTH axes at the length (e.g. 100% x 100%) —
# the line rendered as a full-area slab of line glyphs. The setter now swaps
# the axes wholesale, which also carries an explicit thickness over.
#
# B18-55: `Splitter` had no pane-removal bookkeeping: `remove`/`destroy` on a
# pane left `@panes`/`@dividers`/`@positions` stale — a permanent ghost slot
# and an orphan draggable divider. A `remove` override (mirroring the `#<<`
# override) plus an explicit `remove_widget` API now rebuild the dividers.

private def b18_mem_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

describe "BUGS18 B18-51: Splitter orientation change" do
  it "clears the stale width when switching horizontal -> vertical" do
    s = b18_mem_screen
    sp = Crysterm::Widget::Splitter.new parent: s, width: 62, height: 20
    a = Crysterm::Widget::Box.new
    b = Crysterm::Widget::Box.new
    sp.add_widget a
    sp.add_widget b
    a.width.should eq 30 # (62 - 1) // 2

    sp.orientation = Tput::Orientation::Vertical
    sp.orientation.vertical?.should be_true

    # The setter relayouts immediately; the old horizontal extent must be gone
    # so the `left: 0`/`right: 0` stretch takes effect.
    a.width.should be_nil
    a.height.should eq 9 # (20 - 1) // 2
    a.left.should eq 0
    a.right.should eq 0

    # Rendered, the first pane spans the splitter's full interior width.
    s.repaint
    lp = a.lpos.not_nil!
    (lp.xl - lp.xi).should eq 62
  end

  it "clears the stale height when switching vertical -> horizontal" do
    s = b18_mem_screen
    sp = Crysterm::Widget::Splitter.new parent: s,
      orientation: Tput::Orientation::Vertical, width: 62, height: 20
    a = Crysterm::Widget::Box.new
    b = Crysterm::Widget::Box.new
    sp.add_widget a
    sp.add_widget b
    a.height.should eq 9

    sp.orientation = Tput::Orientation::Horizontal

    a.height.should be_nil
    a.width.should eq 30
    a.top.should eq 0
    a.bottom.should eq 0

    s.repaint
    lp = a.lpos.not_nil!
    (lp.yl - lp.yi).should eq 20
  end

  it "clears the divider's stale opposite anchor on a flip" do
    s = b18_mem_screen
    sp = Crysterm::Widget::Splitter.new parent: s,
      orientation: Tput::Orientation::Vertical, width: 40, height: 20
    sp.add_widget Crysterm::Widget::Box.new
    sp.add_widget Crysterm::Widget::Box.new
    div = sp.dividers[0]
    div.right.should eq 0

    sp.orientation = Tput::Orientation::Horizontal
    div.right.should be_nil # stale `right: 0` from the vertical layout cleared
    div.width.should eq 1
    div.height.should be_nil
  end
end

describe "BUGS18 B18-52: Line#orientation= axis swap" do
  it "moves a default horizontal line's length to the vertical axis and back" do
    s = b18_mem_screen
    l = Crysterm::Widget::HLine.new parent: s, top: 5
    l.width.should eq "100%"
    l.height.should be_nil

    l.orientation = Tput::Orientation::Vertical
    l.width.should be_nil
    l.height.should eq "100%"

    # One column wide, not a full-area slab of glyphs.
    s.repaint
    lp = l.lpos.not_nil!
    (lp.xl - lp.xi).should eq 1

    l.orientation = Tput::Orientation::Horizontal
    l.width.should eq "100%"
    l.height.should be_nil
  end

  it "carries an explicit thickness over to the new axis" do
    s = b18_mem_screen
    l = Crysterm::Widget::Line.new parent: s, top: 2, left: 2, width: 20, height: 3
    l.orientation = Tput::Orientation::Vertical
    l.width.should eq 3
    l.height.should eq 20
  end
end

describe "BUGS18 B18-55: Splitter pane removal bookkeeping" do
  it "unregisters a destroyed pane and rebuilds the dividers" do
    s = b18_mem_screen
    sp = Crysterm::Widget::Splitter.new parent: s, width: 40, height: 10
    a = Crysterm::Widget::Box.new
    b = Crysterm::Widget::Box.new
    c = Crysterm::Widget::Box.new
    sp << a << b << c
    sp.count.should eq 3
    old_dividers = sp.dividers
    old_dividers.size.should eq 2

    b.destroy

    sp.count.should eq 2
    sp.panes.should eq [a, c]
    sp.dividers.size.should eq 1
    sp.sizes.size.should eq 2
    sp.children.includes?(b).should be_false
    # The old divider boxes were detached along with the rebuild.
    old_dividers.each { |d| sp.children.includes?(d).should be_false }

    # The surviving panes re-even across the whole span, no ghost slot.
    a.width.should eq 19 # (40 - 1) // 2
    c.left.should eq 20
    c.right.should eq 0
  end

  it "remove_widget detaches a pane and returns it; nil for a non-pane" do
    s = b18_mem_screen
    sp = Crysterm::Widget::Splitter.new parent: s, width: 40, height: 10
    a = Crysterm::Widget::Box.new
    b = Crysterm::Widget::Box.new
    sp << a << b

    stranger = Crysterm::Widget::Box.new parent: s
    sp.remove_widget(stranger).should be_nil

    sp.remove_widget(a).should be a
    sp.count.should eq 1
    sp.panes.should eq [b]
    sp.dividers.should be_empty
    a.parent.should be_nil

    # The remaining pane is laid out as the last (and only) pane: stretched.
    b.left.should eq 0
    b.right.should eq 0
    b.width.should be_nil
  end

  it "handles a generic remove() the same as remove_widget" do
    s = b18_mem_screen
    sp = Crysterm::Widget::Splitter.new parent: s, width: 40, height: 10
    a = Crysterm::Widget::Box.new
    b = Crysterm::Widget::Box.new
    sp << a << b

    sp.remove b
    sp.count.should eq 1
    sp.panes.should eq [a]
    sp.dividers.should be_empty
  end
end
