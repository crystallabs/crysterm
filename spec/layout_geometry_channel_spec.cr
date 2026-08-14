require "./spec_helper"

include Crysterm

# §4.4 / plans/SIZE-POLICY-PLAN.md Phase 2 — the layout-geometry channel.
# Engines place children through `Widget#set_layout_geometry`, never the
# children's own specs: `w.width`/`w.left` always read what the user set,
# reclaim is exact (any non-nil spec), a stable layout emits no events, and
# removing the layout (or the child) reverts geometry to the specs.

private def rendered_rect(el)
  l = el.lpos.not_nil!
  {l.xi, l.yi, l.xl - l.xi, l.yl - l.yi}
end

describe "layout-geometry channel (§4.4)" do
  it "never writes the specs: a flex child's width/height stay nil after arranging" do
    s = headless_screen(80, 24)
    box = Widget::Box.new parent: s, left: 0, top: 0, width: 30, height: 10,
      layout: Layout::HBox.new
    child = Widget::Box.new parent: box # everything auto

    s.repaint
    child.width.should be_nil
    child.height.should be_nil
    child.left.should be_nil
    child.top.should be_nil
    child.awidth.should eq 30 # the assignment lives in the layout channel
    child.aheight.should eq 10
  end

  it "keeps a Grid child's percent spec intact (the engine with no old bookkeeping)" do
    s = headless_screen(80, 24)
    box = Widget::Box.new parent: s, left: 0, top: 0, width: 30, height: 10,
      layout: Layout::Grid.new(columns: 3, spacing: 0)
    child = Widget::Box.new parent: box, width: "50%",
      layout_hint: Layout::Grid::Hint.new(row: 0, column: 0)

    s.repaint
    child.awidth.should eq 10             # the grid cell decides while managed
    child.width.should eq Dim.percent(50) # the spec survives untouched
  end

  it "reclaims exactly: setting the very value the layout assigned makes the child fixed" do
    s = headless_screen(80, 24)
    box = Widget::Box.new parent: s, left: 0, top: 0, width: 30, height: 4,
      layout: Layout::HBox.new
    c1 = Widget::Box.new parent: box
    c2 = Widget::Box.new parent: box

    s.repaint
    c1.awidth.should eq 15 # two equal flex shares

    # The old shadow-map heuristic (raw == last-assigned => still managed)
    # would swallow this write; spec-based ownership honors it.
    c1.width = 15
    box.width = 20
    s.repaint
    c1.awidth.should eq 15 # fixed at the user's 15
    c2.awidth.should eq 5  # the remaining flex child takes what's left
  end

  it "emits no Move/Resize on a stable frame; a real change still emits" do
    s = headless_screen(80, 24)
    box = Widget::Box.new parent: s, left: 0, top: 0, width: 30, height: 10,
      layout: Layout::HBox.new
    child = Widget::Box.new parent: box

    s.repaint
    events = 0
    child.on(Crysterm::Event::Resize) { events += 1 }
    child.on(Crysterm::Event::Move) { events += 1 }

    s.repaint
    events.should eq 0 # stable layout: no churn

    box.width = 24
    s.repaint
    events.should be > 0 # the flex share genuinely changed
  end

  it "reverts to the specs when the layout is removed" do
    s = headless_screen(80, 24)
    box = Widget::Box.new parent: s, left: 0, top: 0, width: 30, height: 10,
      layout: Layout::VBox.new
    child = Widget::Box.new parent: box, left: 4, top: 2, width: 6, height: 3

    s.repaint
    # VBox pins the position (origin) but keeps the explicit sizes — only a
    # nil size is layout-decided.
    rendered_rect(child).should eq({0, 0, 6, 3})

    box.layout = nil
    s.repaint
    rendered_rect(child).should eq({4, 2, 6, 3}) # own specs again
  end

  it "reverts to the specs when the child leaves the container" do
    s = headless_screen(80, 24)
    grid = Widget::Box.new parent: s, left: 0, top: 0, width: 30, height: 10,
      layout: Layout::Grid.new(columns: 3, spacing: 0)
    plain = Widget::Box.new parent: s, left: 40, top: 0, width: 30, height: 10
    child = Widget::Box.new parent: grid, width: 6, height: 3,
      layout_hint: Layout::Grid::Hint.new(row: 0, column: 1)

    s.repaint
    child.awidth.should eq 10 # grid cell

    grid.remove child
    child.layout_hint = nil
    plain.append child
    s.repaint
    child.awidth.should eq 6 # own spec again, no stale cell size
    rendered_rect(child).should eq({40, 0, 6, 3})
  end

  it "keeps a Stack page's own position spec for after the layout goes away" do
    s = headless_screen(80, 24)
    box = Widget::Box.new parent: s, left: 0, top: 0, width: 30, height: 10,
      layout: Layout::Stack.new
    page = Widget::Box.new parent: box, left: 5, top: 2, width: 6, height: 3

    s.repaint
    rendered_rect(page)[0].should eq 0 # stack pins the page at the origin
    page.left.should eq 5              # the spec survives

    box.layout = nil
    s.repaint
    rendered_rect(page).should eq({5, 2, 6, 3})
  end
end
