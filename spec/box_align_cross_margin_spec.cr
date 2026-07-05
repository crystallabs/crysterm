require "./spec_helper"

include Crysterm

# The Stretch cross-axis branch of `Layout::Box#place` reserves a child's
# cross-axis margins (BUGS8 §5), but the non-stretch `Center`/`End` branch did
# not: it computed the offset from the border size alone (`cross - cs`), while
# the render pipeline still shifts the border box out by the child's near
# margin. So an `End`-aligned margined child overflowed the far edge by that
# margin (and `Center` mis-centered / overflowed) — the cross-axis analogue of
# the already-fixed Stretch case. Same headless harness as `bugs8_layout_spec`.

private def headless_screen(w = 80, h = 24)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

private def render_children(s, container)
  s._render
  container.children.map do |c|
    l = c.lpos.not_nil!
    {l.xi, l.xl, l.yi, l.yl}
  end
end

describe "Box non-stretch cross-axis align reserves child margins" do
  it "keeps an End-aligned child's margin box flush against the far edge" do
    s = headless_screen
    # Cross axis is height (HBox). Interior height 10; child height 4 with a
    # 2-cell top and bottom margin.
    box = Widget::Box.new parent: s, left: 0, top: 0, width: 20, height: 10,
      layout: Layout::HBox.new(align: Layout::Box::Align::End)
    Widget::Box.new parent: box, width: 6, height: 4,
      style: Style.new(margin: Margin.new(left: 0, top: 2, right: 0, bottom: 2))

    rect = render_children(s, box)[0]
    # Margin box flush to the bottom: border box far edge at 10 - 2 = 8, near at
    # 4. Pre-fix it rendered {0,6,8,12}, overflowing the interior by 2.
    rect.should eq({0, 6, 4, 8})
    rect[3].should be <= 10 # bottom edge does not overflow the interior height
  end

  it "centers a Center-aligned child's margin box symmetrically" do
    s = headless_screen
    box = Widget::Box.new parent: s, left: 0, top: 0, width: 20, height: 10,
      layout: Layout::HBox.new(align: Layout::Box::Align::Center)
    Widget::Box.new parent: box, width: 6, height: 4,
      style: Style.new(margin: Margin.new(left: 0, top: 2, right: 0, bottom: 2))

    rect = render_children(s, box)[0]
    # Margin box height 4 + 2 + 2 = 8, centered in 10 -> margin box [1, 9],
    # border box [3, 7]. Pre-fix it rendered {0,6,5,9}, overflowing to row 11.
    rect.should eq({0, 6, 3, 7})
    rect[3].should be <= 10
  end

  it "still places a Start-aligned margined child at its near margin" do
    s = headless_screen
    box = Widget::Box.new parent: s, left: 0, top: 0, width: 20, height: 10,
      layout: Layout::HBox.new(align: Layout::Box::Align::Start)
    Widget::Box.new parent: box, width: 6, height: 4,
      style: Style.new(margin: Margin.new(left: 0, top: 2, right: 0, bottom: 2))

    rect = render_children(s, box)[0]
    rect.should eq({0, 6, 2, 6}) # near (top) margin of 2, unchanged by the fix
  end
end
