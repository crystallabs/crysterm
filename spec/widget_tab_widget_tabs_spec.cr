require "./spec_helper"

include Crysterm

private def tab_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

# Behavioral specs for `Widget::TabWidget`'s tab-collection management
# (rendering/switching is covered elsewhere): add/remove/close/move and the
# wrapping next/previous, plus the closable `✕` marker.
describe Crysterm::Widget::TabWidget do
  describe "#add_tab" do
    it "tracks titles/pages, makes the first tab current, and hides the rest" do
      s = tab_screen
      tabs = Crysterm::Widget::TabWidget.new parent: s, width: 60, height: 20
      p1 = Crysterm::Widget::Box.new content: "one"
      p2 = Crysterm::Widget::Box.new content: "two"
      tabs.add_tab "First", p1
      tabs.add_tab "Second", p2

      tabs.tab_titles.should eq ["First", "Second"]
      tabs.pages.should eq [p1, p2]
      tabs.current_index.should eq 0
      tabs.current_widget.should be(p1)
      p1.visible?.should be_true
      p2.visible?.should be_false # only the current page shows
    end
  end

  describe "#insert_tab" do
    it "inserts at an index (clamped) and keeps the current page current" do
      s = tab_screen
      tabs = Crysterm::Widget::TabWidget.new parent: s, width: 60, height: 20
      pa = Crysterm::Widget::Box.new
      pc = Crysterm::Widget::Box.new
      tabs.add_tab "A", pa
      tabs.add_tab "C", pc
      tabs.next_tab # current => C (index 1)

      pb = Crysterm::Widget::Box.new
      tabs.insert_tab(1, "B", pb).should eq 1
      tabs.tab_titles.should eq ["A", "B", "C"]
      tabs.count.should eq 3
      # C is still the page on screen; it just moved along by one.
      tabs.current_widget.should be(pc)
      tabs.current_index.should eq 2
      tabs.tab_bar.current_index.should eq 2 # and the bar's highlight followed it
      pb.visible?.should be_false

      tabs.insert_tab(99, "D", Crysterm::Widget::Box.new).should eq 3 # clamped
      tabs.tab_titles.should eq ["A", "B", "C", "D"]
    end

    it "makes the first tab inserted current" do
      s = tab_screen
      tabs = Crysterm::Widget::TabWidget.new parent: s, width: 60, height: 20
      p0 = Crysterm::Widget::Box.new
      tabs.insert_tab 0, "Only", p0
      tabs.current_index.should eq 0
      tabs.current_widget.should be(p0)
      p0.visible?.should be_true
    end
  end

  describe "#tab_text / #set_tab_text" do
    it "reads and rewrites a tab's title, refreshing the bar" do
      s = tab_screen
      tabs = Crysterm::Widget::TabWidget.new parent: s, width: 60, height: 20
      tabs.add_tab "A", Crysterm::Widget::Box.new
      tabs.add_tab "B", Crysterm::Widget::Box.new
      tabs.next_tab

      tabs.tab_text(1).should eq "B"
      tabs.tab_text(9).should be_nil
      tabs.tab_text(-1).should be_nil # never counts from the end

      tabs.set_tab_text 1, "Bee"
      tabs.tab_text(1).should eq "Bee"
      tabs.tab_bar.item_texts.should eq ["A", "Bee"]
      tabs.tab_bar.current_index.should eq 1 # rebuild kept the highlight on the current tab
    end
  end

  describe "#current_widget=" do
    it "raises the given page" do
      s = tab_screen
      tabs = Crysterm::Widget::TabWidget.new parent: s, width: 60, height: 20
      p1 = Crysterm::Widget::Box.new
      p2 = Crysterm::Widget::Box.new
      tabs.add_tab "A", p1
      tabs.add_tab "B", p2

      tabs.current_widget = p2
      tabs.current_index.should eq 1
      p2.visible?.should be_true

      tabs.current_widget = Crysterm::Widget::Box.new # not ours: no-op
      tabs.current_index.should eq 1
    end
  end

  describe "Event::CurrentChanged" do
    it "reports every switch, and -1 once the last tab is gone" do
      s = tab_screen
      tabs = Crysterm::Widget::TabWidget.new parent: s, width: 60, height: 20
      seen = [] of Int32
      tabs.on(Crysterm::Event::CurrentChanged) { |e| seen << e.index }

      tabs.add_tab "A", Crysterm::Widget::Box.new # first page becomes current
      tabs.add_tab "B", Crysterm::Widget::Box.new
      tabs.next_tab
      tabs.remove_tab 1
      tabs.remove_tab 0 # container now empty
      seen.should eq [0, 1, 0, -1]
    end
  end

  describe "#next_tab / #previous_tab" do
    it "wraps around both ends" do
      s = tab_screen
      tabs = Crysterm::Widget::TabWidget.new parent: s, width: 40, height: 10
      3.times { |i| tabs.add_tab "T#{i}", Crysterm::Widget::Box.new }
      tabs.current_index.should eq 0
      tabs.next_tab
      tabs.current_index.should eq 1
      tabs.previous_tab
      tabs.previous_tab # wraps 0 -> 2
      tabs.current_index.should eq 2
      tabs.next_tab # wraps 2 -> 0
      tabs.current_index.should eq 0
    end
  end

  describe "#remove_tab" do
    it "detaches (does not destroy) the page and keeps a valid current tab" do
      s = tab_screen
      tabs = Crysterm::Widget::TabWidget.new parent: s, width: 40, height: 10
      p0 = Crysterm::Widget::Box.new content: "a"
      p1 = Crysterm::Widget::Box.new content: "b"
      tabs.add_tab "A", p0
      tabs.add_tab "B", p1

      destroyed = false
      p0.on(Crysterm::Event::Destroy) { destroyed = true }
      removed = false
      tabs.on(Crysterm::Event::ItemRemoved) { removed = true }

      returned = tabs.remove_tab 0
      returned.should be(p0)    # returns the detached page (Qt's removeTab)
      destroyed.should be_false # detached, not destroyed
      removed.should be_true
      tabs.tab_titles.should eq ["B"]
      tabs.pages.should eq [p1]
      tabs.current_widget.should be(p1)
    end

    it "returns nil for an out-of-range index" do
      s = tab_screen
      tabs = Crysterm::Widget::TabWidget.new parent: s, width: 40, height: 10
      tabs.add_tab "A", Crysterm::Widget::Box.new
      tabs.remove_tab(5).should be_nil
      tabs.remove_tab(-1).should be_nil
    end
  end

  describe "#close_tab" do
    it "removes and destroys the page" do
      s = tab_screen
      tabs = Crysterm::Widget::TabWidget.new parent: s, width: 40, height: 10
      p0 = Crysterm::Widget::Box.new
      tabs.add_tab "A", p0
      tabs.add_tab "B", Crysterm::Widget::Box.new

      destroyed = false
      p0.on(Crysterm::Event::Destroy) { destroyed = true }
      tabs.close_tab 0
      destroyed.should be_true
      tabs.pages.size.should eq 1
    end
  end

  describe "#move_tab" do
    it "reorders titles/pages while keeping the same page current" do
      s = tab_screen
      tabs = Crysterm::Widget::TabWidget.new parent: s, movable: true, width: 40, height: 10
      p0 = Crysterm::Widget::Box.new
      p1 = Crysterm::Widget::Box.new
      p2 = Crysterm::Widget::Box.new
      tabs.add_tab "A", p0
      tabs.add_tab "B", p1
      tabs.add_tab "C", p2
      tabs.next_tab # current => B (index 1)
      tabs.current_widget.should be(p1)

      tabs.move_tab 1, 0 # move B to the front
      tabs.tab_titles.should eq ["B", "A", "C"]
      tabs.pages.should eq [p1, p0, p2]
      tabs.current_widget.should be(p1) # same page stays current, now at index 0
      tabs.current_index.should eq 0
    end

    it "clamps the destination and no-ops when unchanged" do
      s = tab_screen
      tabs = Crysterm::Widget::TabWidget.new parent: s, movable: true, width: 40, height: 10
      tabs.add_tab "A", Crysterm::Widget::Box.new
      tabs.add_tab "B", Crysterm::Widget::Box.new
      tabs.move_tab 0, 99 # clamps to last
      tabs.tab_titles.should eq ["B", "A"]
    end
  end

  describe "closable tabs" do
    it "shows a ✕ marker in the bar item titles" do
      s = tab_screen
      tabs = Crysterm::Widget::TabWidget.new parent: s, tabs_closable: true, width: 40, height: 10
      tabs.add_tab "Files", Crysterm::Widget::Box.new
      # ListBar prefixes each item with its command number ("1:"); the tab's
      # display title (with the ✕ close marker) is the trailing part.
      tabs.tab_bar.items.first.content.ends_with?("Files ✕").should be_true
    end
  end
end
