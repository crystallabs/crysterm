require "./spec_helper"

include Crysterm

# Lifecycle invariants shared by the insert/remove/visibility paths:
#
#   * `Window#widget_at`'s hover memo answers for the current *tree*, not just
#     the current frame — removing or hiding a widget must be visible to the
#     very next hit test, with no render in between (`Window#click` dispatches
#     press and release back to back).
#   * `Widget#insert` takes any index: out-of-range clamps to the ends, the way
#     `Window#insert` and Qt's `insertWidget` do.
#   * `Event::Attached` fires exactly once when a widget first enters a tree,
#     including a stand-alone widget that already holds the auto-assigned global
#     window, and is not repeated for a move that stays on the same window.

describe "hover memo across structural and visibility changes" do
  it "hits the widget underneath right after a top-level removal" do
    s = headless_screen(40, 30)
    under = Widget::Box.new parent: s, left: 0, top: 0, width: 20, height: 10
    under.clickable = true
    over = Widget::Box.new parent: s, left: 2, top: 2, width: 10, height: 4
    over.clickable = true
    s.repaint

    # Memoize the answer for this cell, then remove the widget it names without
    # an intervening render.
    s.widget_at(4, 3).try(&.same?(over)).should be_true
    s.remove over
    s.widget_at(4, 3).try(&.same?(under)).should be_true
  ensure
    s.try &.destroy
  end

  it "hits the container right after a nested child is removed" do
    s = headless_screen(40, 30)
    c = Widget::Box.new parent: s, left: 0, top: 0, width: 20, height: 10
    c.clickable = true
    over = Widget::Box.new parent: c, left: 2, top: 2, width: 10, height: 4
    over.clickable = true
    s.repaint

    s.widget_at(4, 3).try(&.same?(over)).should be_true
    c.remove over
    s.widget_at(4, 3).try(&.same?(c)).should be_true
  ensure
    s.try &.destroy
  end

  it "stops (and resumes) hitting a widget across hide/show" do
    s = headless_screen(40, 30)
    under = Widget::Box.new parent: s, left: 0, top: 0, width: 20, height: 10
    under.clickable = true
    over = Widget::Box.new parent: s, left: 2, top: 2, width: 10, height: 4
    over.clickable = true
    s.repaint

    s.widget_at(4, 3).try(&.same?(over)).should be_true
    over.hide
    s.widget_at(4, 3).try(&.same?(under)).should be_true
    over.show
    s.widget_at(4, 3).try(&.same?(over)).should be_true
  ensure
    s.try &.destroy
  end

  it "does not deliver the release of a press that removed the widget" do
    s = headless_screen(40, 30)
    under = Widget::Box.new parent: s, left: 0, top: 0, width: 20, height: 10
    under.clickable = true
    over = Widget::Box.new parent: s, left: 2, top: 2, width: 10, height: 4
    over.clickable = true
    seen = [] of ::Tput::Mouse::Action
    over.on(Crysterm::Event::Mouse) do |e|
      seen << e.action
      s.remove over if e.action.down?
    end
    s.repaint

    # Press and release land in one call, with no frame between them.
    s.click 4, 3

    seen.should eq [::Tput::Mouse::Action::Down]
    # The release resolved against the current tree, so the hover moved to the
    # widget the removal exposed.
    s.hovered.try(&.same?(under)).should be_true
  ensure
    s.try &.destroy
  end
end

describe "Widget#insert index clamping" do
  it "appends when the index is past the end" do
    s = headless_screen(40, 10)
    c = Widget::Box.new parent: s, width: 20, height: 6
    a = Widget::Box.new parent: c, width: 4, height: 2
    b = Widget::Box.new width: 4, height: 2

    c.insert b, 5

    c.children.size.should eq 2
    c.children[0].same?(a).should be_true
    c.children[1].same?(b).should be_true
  ensure
    s.try &.destroy
  end

  it "prepends when the negative index reaches past the front" do
    s = headless_screen(40, 10)
    c = Widget::Box.new parent: s, width: 20, height: 6
    a = Widget::Box.new parent: c, width: 4, height: 2
    b = Widget::Box.new width: 4, height: 2

    c.insert b, -20

    c.children.size.should eq 2
    c.children[0].same?(b).should be_true
    c.children[1].same?(a).should be_true
  ensure
    s.try &.destroy
  end

  it "keeps the from-the-end meaning of a negative index in range" do
    s = headless_screen(40, 10)
    c = Widget::Box.new parent: s, width: 20, height: 6
    a = Widget::Box.new parent: c, width: 4, height: 2
    b = Widget::Box.new parent: c, width: 4, height: 2
    mid = Widget::Box.new width: 4, height: 2

    # `-1` appends; `-2` lands just before the last child.
    c.insert mid, -2

    c.children[0].same?(a).should be_true
    c.children[1].same?(mid).should be_true
    c.children[2].same?(b).should be_true
  ensure
    s.try &.destroy
  end

  it "clamps through Layout::Box#insert_widget" do
    s = headless_screen(40, 10)
    c = Widget::Box.new parent: s, top: 0, left: 0, width: 40, height: 10,
      layout: :vbox
    a = Widget::Box.new parent: c
    lay = c.layout.not_nil!.as(Layout::Box)

    b = Widget::Box.new
    lay.insert_widget 3, b

    c.children.size.should eq 2
    c.children[0].same?(a).should be_true
    c.children[1].same?(b).should be_true
  ensure
    s.try &.destroy
  end
end

describe "Event::Attached on a first insertion" do
  it "fires once when a stand-alone widget is appended to a container" do
    s = headless_screen(40, 10)
    c = Widget::Box.new parent: s, width: 20, height: 6
    w = Widget::Box.new width: 4, height: 2
    # Built with no parent and no window, so it holds the global window (the
    # most recently created one) without sitting in any children list.
    w.window?.try(&.same?(s)).should be_true

    transitions = [] of String
    w.on(Event::Attached) { transitions << "attach" }
    w.on(Event::Detached) { transitions << "detach" }

    c.append w

    transitions.should eq ["attach"]
    w.parent.try(&.same?(c)).should be_true
  ensure
    s.try &.destroy
  end

  it "fires once when a stand-alone widget is appended to the window" do
    s = headless_screen(40, 10)
    w = Widget::Box.new width: 4, height: 2
    w.window?.try(&.same?(s)).should be_true

    transitions = [] of String
    w.on(Event::Attached) { transitions << "attach" }
    w.on(Event::Detached) { transitions << "detach" }

    s.append w

    transitions.should eq ["attach"]
    s.children.includes?(w).should be_true
  ensure
    s.try &.destroy
  end

  it "fires for the whole subtree of a stand-alone container" do
    s = headless_screen(40, 10)
    c = Widget::Box.new parent: s, width: 20, height: 6
    outer = Widget::Box.new width: 10, height: 4
    inner = Widget::Box.new parent: outer, width: 4, height: 2

    attaches = 0
    inner.on(Event::Attached) { attaches += 1 }

    c.append outer

    attaches.should eq 1
  ensure
    s.try &.destroy
  end

  it "does not repeat Attached for a move between containers on one window" do
    s = headless_screen(40, 10)
    a = Widget::Box.new parent: s, width: 20, height: 6
    b = Widget::Box.new parent: s, width: 20, height: 6
    w = Widget::Box.new width: 4, height: 2

    transitions = [] of String
    w.on(Event::Attached) { transitions << "attach" }
    w.on(Event::Detached) { transitions << "detach" }

    a.append w
    b.append w # same-window move: a tree-position change, not a re-attach

    transitions.should eq ["attach"]
    w.parent.try(&.same?(b)).should be_true
  ensure
    s.try &.destroy
  end

  it "pairs Attached with Detached on removal and re-append" do
    s = headless_screen(40, 10)
    c = Widget::Box.new parent: s, width: 20, height: 6
    w = Widget::Box.new width: 4, height: 2

    transitions = [] of String
    w.on(Event::Attached) { transitions << "attach" }
    w.on(Event::Detached) { transitions << "detach" }

    c.append w
    c.remove w
    c.append w

    transitions.should eq ["attach", "detach", "attach"]
  ensure
    s.try &.destroy
  end

  it "emits one Detached/Attached pair for a genuine cross-window move" do
    s1 = headless_screen(20, 10)
    s2 = headless_screen(20, 10)
    a = Widget::Box.new parent: s1, width: 10, height: 5
    b = Widget::Box.new parent: s2, width: 10, height: 5
    # Explicit window, no parent: attached nowhere, so the first insert is a
    # fresh attach even though the window it names is the destination's.
    w = Widget::Box.new window: s1, width: 4, height: 2

    transitions = [] of String
    w.on(Event::Attached) { transitions << "attach" }
    w.on(Event::Detached) { transitions << "detach" }

    a.append w
    transitions.should eq ["attach"]

    b.append w
    transitions.should eq ["attach", "detach", "attach"]
    w.window?.try(&.same?(s2)).should be_true
  ensure
    s1.try &.destroy
    s2.try &.destroy
  end
end
