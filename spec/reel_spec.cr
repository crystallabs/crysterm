require "./spec_helper"

include Crysterm

# `Widget::Reel` — ring management (add/remove/focus rotation, the shared
# item-container events) and the reel layout: focused tablet fully visible,
# neighbors filling the rows above/below in ring order, edge clipping, and
# the circular vs. non-circular ends.

# The characters actually painted on window row *row*.
private def row_chars(s, row) : String
  (0...s.width).map { |x| s.lines[row][x].char }.join
end

# A reel whose four 5-row tablets carry distinguishable line content
# ("T0L0".."T3L4"), inside a 12-row viewport (total 20 > 12 forces the
# windowed layout).
private def tall_reel(s, circular)
  reel = Crysterm::Widget::Reel.new parent: s, top: 0, left: 0, width: 20, height: 12,
    circular: circular, keys: true
  4.times do |i|
    reel.add_tablet (0...5).map { |l| "T#{i}L#{l}" }.join('\n'), rows: 5
  end
  reel
end

describe Crysterm::Widget::Reel do
  describe "#add_tablet" do
    it "keeps ring order, focuses the first tablet added, and emits ItemAdded/CurrentChanged" do
      s = headless_screen(40, 20)
      reel = Crysterm::Widget::Reel.new parent: s, width: 20, height: 12
      added = 0
      seen = [] of Int32
      reel.on(Crysterm::Event::ItemAdded) { added += 1 }
      reel.on(Crysterm::Event::CurrentChanged) { |e| seen << e.index }

      t0 = reel.add_tablet "zero"
      t1 = reel.add_tablet "one"
      reel.tablets.should eq [t0, t1]
      reel.count.should eq 2
      reel.tablet(0).should be(t0)
      reel.tablet(1).should be(t1)
      reel.tablet(2).should be_nil
      reel.tablet(-1).should be_nil # never counts from the end
      reel.focused_index.should eq 0
      reel.focused_tablet.should be(t0)
      added.should eq 2
      seen.should eq [0] # only the first add changes focus
    ensure
      s.try &.destroy
    end

    it "inserts after:/before: a neighbor and keeps the focused tablet focused" do
      s = headless_screen(40, 20)
      reel = Crysterm::Widget::Reel.new parent: s, width: 20, height: 12
      ta = reel.add_tablet "a"
      tc = reel.add_tablet "c"
      reel.focus_next # focus c

      tb = reel.add_tablet "b", after: ta
      reel.tablets.should eq [ta, tb, tc]
      reel.focused_tablet.should be(tc) # followed its shift
      reel.focused_index.should eq 2

      t_pre = reel.add_tablet "pre", before: ta
      reel.tablets.should eq [t_pre, ta, tb, tc]
      reel.focused_tablet.should be(tc)
      reel.focused_index.should eq 3
    ensure
      s.try &.destroy
    end
  end

  describe "layout" do
    it "stacks all tablets from the top when they fit, honoring variable heights" do
      s = headless_screen(40, 24)
      reel = Crysterm::Widget::Reel.new parent: s, top: 0, left: 0, width: 20, height: 20
      t0 = reel.add_tablet "a", rows: 2
      t1 = reel.add_tablet "b", rows: 5
      t2 = reel.add_tablet "c", rows: 3
      s.repaint

      t0.top.should eq 0
      t1.top.should eq 2
      t2.top.should eq 7
      t1.height.should eq 5
      [t0, t1, t2].each &.visible?.should be_true
    ensure
      s.try &.destroy
    end

    it "measures a content-driven tablet (no fixed rows) from its lines" do
      s = headless_screen(40, 24)
      reel = Crysterm::Widget::Reel.new parent: s, top: 0, left: 0, width: 20, height: 20
      t0 = reel.add_tablet "one\ntwo\nthree"
      t1 = reel.add_tablet "x", rows: 2
      s.repaint

      t0.height.should eq 3
      t1.top.should eq 3
    ensure
      s.try &.destroy
    end

    it "windows the ring around the focused tablet and clips the overflow at the bottom edge" do
      s = headless_screen(40, 20)
      reel = tall_reel s, circular: true
      t = reel.tablets
      s.repaint

      # Focused t0 at the top; t1 whole below it; t2 clipped by the viewport.
      reel.focused_index.should eq 0
      t[0].top.should eq 0
      t[1].top.should eq 5
      t[2].top.should eq 10
      t[2].visible?.should be_true
      t[3].visible?.should be_false # no rows left for it

      row_chars(s, 10).should contain "T2L0"
      row_chars(s, 11).should contain "T2L1"
      # t2's remaining rows fall outside the reel and must not paint there.
      row_chars(s, 12).should_not contain "T2L2"
    ensure
      s.try &.destroy
    end

    it "rolls the ring around a stable focus position, clipping at the top edge" do
      s = headless_screen(40, 20)
      reel = tall_reel s, circular: true
      t = reel.tablets
      s.repaint

      # t2 was on screen at row 10; refocusing pins it fully visible at the
      # closest in-range position (12 - 5 = 7) with its predecessors above.
      reel.focused_index = 2
      s.repaint

      t[2].top.should eq 7
      t[1].top.should eq 2
      t[0].top.should eq -3 # clips: only its last two rows remain
      t[3].visible?.should be_false

      row_chars(s, 0).should contain "T0L3"
      row_chars(s, 1).should contain "T0L4"
      row_chars(s, 0).should_not contain "T0L0"
    ensure
      s.try &.destroy
    end

    it "wraps tablets around the ring to fill both sides when circular" do
      s = headless_screen(40, 20)
      reel = tall_reel s, circular: true
      t = reel.tablets
      s.repaint
      reel.focus_next # t1 keeps its on-screen position (row 5)...
      s.repaint

      t[1].top.should eq 5
      t[0].top.should eq 0
      t[2].top.should eq 10

      # ...so focusing the off-screen t3 surfaces it there, with its ring
      # predecessor t2 above and its ring successor t0 wrapped in below.
      reel.focused_index = 3
      s.repaint

      t[3].top.should eq 5
      t[2].top.should eq 0
      t[0].top.should eq 10
      t[1].visible?.should be_false

      row_chars(s, 0).should contain "T2L0"
      row_chars(s, 5).should contain "T3L0"
      row_chars(s, 10).should contain "T0L0"
    ensure
      s.try &.destroy
    end

    it "fills only from the ring's own ends when non-circular" do
      s = headless_screen(40, 20)
      reel = tall_reel s, circular: false
      t = reel.tablets
      s.repaint

      # Focusing the last tablet pulls it to the bottom (no wrap below it to
      # fill from), with its predecessors stacked above.
      reel.focused_index = 3
      s.repaint

      t[3].top.should eq 7
      t[2].top.should eq 2
      t[1].top.should eq(-3)
      t[0].visible?.should be_false

      row_chars(s, 11).should contain "T3L4" # reel bottom row
    ensure
      s.try &.destroy
    end
  end

  describe "#focus_next / #focus_previous" do
    it "wraps around both ends when circular" do
      s = headless_screen(40, 20)
      reel = Crysterm::Widget::Reel.new parent: s, width: 20, height: 12, circular: true
      3.times { |i| reel.add_tablet "t#{i}" }

      reel.focus_previous # wraps 0 -> 2
      reel.focused_index.should eq 2
      reel.focus_next # wraps 2 -> 0
      reel.focused_index.should eq 0
      reel.focus_prev
      reel.focused_index.should eq 2
    ensure
      s.try &.destroy
    end

    it "stops at the ends when non-circular" do
      s = headless_screen(40, 20)
      reel = Crysterm::Widget::Reel.new parent: s, width: 20, height: 12, circular: false
      3.times { |i| reel.add_tablet "t#{i}" }
      seen = [] of Int32
      reel.on(Crysterm::Event::CurrentChanged) { |e| seen << e.index }

      reel.focus_previous # no-op at the start
      reel.focused_index.should eq 0
      reel.focus_next
      reel.focus_next
      reel.focus_next # no-op at the end
      reel.focused_index.should eq 2
      seen.should eq [1, 2]
    ensure
      s.try &.destroy
    end

    it "rotates focus from the arrow keys" do
      s = headless_screen(40, 20)
      reel = tall_reel s, circular: true
      s.repaint

      reel.emit Crysterm::Event::KeyPress.new '\0', ::Tput::Key::Down
      reel.focused_index.should eq 1
      reel.emit Crysterm::Event::KeyPress.new '\0', ::Tput::Key::Up
      reel.focused_index.should eq 0
      reel.emit Crysterm::Event::KeyPress.new '\0', ::Tput::Key::End
      reel.focused_index.should eq 3
      reel.emit Crysterm::Event::KeyPress.new '\0', ::Tput::Key::Home
      reel.focused_index.should eq 0
    ensure
      s.try &.destroy
    end
  end

  describe "#remove_tablet" do
    it "detaches (does not destroy) the tablet and keeps a valid focus, mid-display" do
      s = headless_screen(40, 20)
      reel = tall_reel s, circular: true
      t = reel.tablets.dup
      s.repaint

      destroyed = false
      t[0].on(Crysterm::Event::Destroy) { destroyed = true }
      removed = 0
      reel.on(Crysterm::Event::ItemRemoved) { removed += 1 }

      reel.remove_tablet(t[0]).should be(t[0]) # the focused one
      destroyed.should be_false
      removed.should eq 1
      reel.tablets.should eq [t[1], t[2], t[3]]
      reel.focused_tablet.should be(t[1]) # neighbor slid into the slot
      s.repaint
      row_chars(s, 0).should contain "T1L0"

      reel.remove_tablet(t[3]).should be(t[3]) # a non-focused one
      reel.focused_tablet.should be(t[1])
      reel.remove_tablet(t[3]).should be_nil # no longer ours
    ensure
      s.try &.destroy
    end

    it "reports -1 once the last tablet is gone, and reels back up from empty" do
      s = headless_screen(40, 20)
      reel = Crysterm::Widget::Reel.new parent: s, top: 0, left: 0, width: 20, height: 12
      seen = [] of Int32
      reel.on(Crysterm::Event::CurrentChanged) { |e| seen << e.index }

      reel.add_tablet "a"
      reel.remove_tablet 0
      reel.focused_index.should eq -1
      reel.focused_tablet.should be_nil

      reel.add_tablet "b"
      reel.focused_index.should eq 0
      seen.should eq [0, -1, 0]
    ensure
      s.try &.destroy
    end

    it "catches a tablet destroyed directly (not via remove_tablet)" do
      s = headless_screen(40, 20)
      reel = tall_reel s, circular: true
      t = reel.tablets.dup
      removed = false
      reel.on(Crysterm::Event::ItemRemoved) { removed = true }

      t[1].destroy
      removed.should be_true
      reel.tablets.should eq [t[0], t[2], t[3]]
      reel.focused_tablet.should be(t[0])
    ensure
      s.try &.destroy
    end
  end

  describe "click" do
    it "focuses the clicked tablet" do
      s = headless_screen(40, 20)
      reel = tall_reel s, circular: true
      s.repaint

      click s, 2, 7 # inside t1 (rows 5..9)
      reel.focused_index.should eq 1
    ensure
      s.try &.destroy
    end
  end
end
