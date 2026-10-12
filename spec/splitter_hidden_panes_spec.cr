require "./spec_helper"

# `Splitter` in Qt's `QSplitter` model: the panes' wanted extents are the
# state, the dividers follow. A hidden pane takes no room and its divider is
# hidden; a resize keeps the proportions set by hand; stretch factors pin a
# column; `#save_state`/`#restore_state` carry the layout across runs.

private def three_panes(width = 31)
  s = headless_screen(80, 24)
  sp = Crysterm::Widget::Splitter.new parent: s, width: width, height: 10
  a = Crysterm::Widget::Box.new
  b = Crysterm::Widget::Box.new
  c = Crysterm::Widget::Box.new
  sp << a << b << c
  {s, sp, a, b, c}
end

describe "Splitter hidden panes" do
  it "gives a hidden pane's room to the others and hides its divider" do
    s, sp, a, b, c = three_panes
    s.repaint
    sp.sizes.should eq [9, 9, 11]
    sp.dividers.map(&.visible?).should eq [true, true]

    c.hide
    sp.sizes.should eq [15, 15, 0]
    sp.dividers.map(&.visible?).should eq [true, false]
    b.right.should eq 0 # the last shown pane fills to the edge
    s.repaint

    c.show
    sp.sizes.should eq [9, 9, 11]
    sp.dividers.map(&.visible?).should eq [true, true]

    b.hide
    sp.sizes.should eq [15, 0, 15]
    sp.dividers.map(&.visible?).should eq [true, false]
    sp.dividers[0].position.should eq 15
    a.width_spec.should eq 15
    c.left.should eq 16
  end

  it "keeps the proportions set by hand across a resize" do
    _, sp, a, b, c = three_panes
    sp.dividers[0].position = 5
    sp.sizes.should eq [5, 13, 11]

    sp.width = 61
    sp.sizes.should eq [10, 26, 23]
    [a, b, c].each &.visible?.should(be_true)

    # Never sized: an even split, re-fitted to the span.
    _, sp2 = three_panes
    sp2.width = 61
    sp2.sizes.should eq [19, 19, 21]
  end

  it "pins the panes without a stretch factor and stretches the others" do
    _, sp, _, _, c = three_panes
    sp.set_stretch_factor 0, 1
    sp.set_stretch_factor 1, 1
    sp.stretch_factor(1).should eq 1
    sp.stretch_factor(2).should eq 0
    sp.sizes = [0, 0, 8]
    sp.sizes.should eq [10, 11, 8]

    sp.width = 51
    sp.sizes.should eq [20, 21, 8] # the fixed column keeps its cells

    c.hide
    sp.sizes.should eq [25, 25, 0]
    c.show
    sp.sizes.should eq [20, 21, 8]

    # A drag onto the fixed column resizes it, and the new extent is kept.
    sp.dividers[1].position = 25
    sp.sizes.should eq [20, 4, 25]
  end

  it "saves and restores the layout, hidden panes' extents included" do
    _, sp, _, _, c = three_panes
    sp.sizes = [5, 10]
    sp.save_state.should eq [5, 10, 14]

    _, sp2, _, _, c2 = three_panes(61)
    sp2.restore_state(sp.save_state).should be_true
    sp2.sizes.should eq [10, 20, 29] # the same proportions in a wider span
    sp2.restore_state([1, 2]).should be_false
    sp2.restore_state([] of Int32).should be_false
    sp2.sizes.should eq [10, 20, 29]

    c2.hide
    sp2.dividers[0].position = 30
    sp2.sizes.should eq [30, 30, 0]
    sp2.save_state.should eq [30, 30, 14] # the hidden pane remembers
    c2.show
    sp2.sizes.should eq [23, 23, 13]
    c.visible?.should be_true

    # A pane hidden before the restore takes its extent too, for when it is
    # shown; the shown panes share the span meanwhile.
    _, sp3, _, _, c3 = three_panes(61)
    c3.hide
    sp3.restore_state([5, 10, 14]).should be_true
    sp3.sizes.should eq [20, 40, 0]
    sp3.save_state.should eq [5, 10, 14]
    c3.show
    sp3.sizes.should eq [10, 20, 29]
  end

  it "keeps its dividers off the Tab chain" do
    _, sp = three_panes
    sp.dividers.each do |div|
      div.focus_policy.click?.should be_true
      div.accepts_tab_focus?.should be_false
    end
  end
end
