require "./spec_helper"

include Crysterm

# Regression specs for BUGS15 #20, #54, #55. Headless harness mirrors
# spec/bugs12_layout_spec.cr.

private def headless_screen(w = 80, h = 24)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

# BUGS15 #20 — a border label (and a bound scroll bar) is internal chrome, but
# any installed *arranging* layout engine treated it as a content slot: VBox
# counted the title Box in its flex distribution and overwrote its
# border-glued position, tearing the title off the border into a stray inner
# bar and starving the real children. The fix flags such chrome
# `layout_chrome?`, has `Layout#each_arrangeable` skip it, and paints it via
# `Layout#render_chrome` at its own pinned coordinates.
describe "BUGS15 20: layout engines do not arrange border-label/scrollbar chrome" do
  it "keeps a VBox-container's title on the border row, not in a content slot" do
    s = headless_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 30, height: 12,
      layout: Layout::VBox.new, style: Style.new(border: true)
    box.set_label "Settings"
    lbl = box._label.not_nil!

    # Two real content children.
    c1 = Widget::Box.new parent: box
    c2 = Widget::Box.new parent: box

    s._render

    box.itop.should eq 1 # border reserves one row
    lbl.layout_chrome?.should be_true

    # The label is glued to the border row (pinned top == -itop), NOT arranged
    # into interior slot 0 (which would give a non-negative top).
    lbl.top.should eq(-box.itop)
    lbl.lpos.should_not be_nil # still painted (out-of-band by render_chrome)

    bl = box.lpos.not_nil!
    interior_top = bl.yi + box.itop

    # First real child starts at the interior top — the label consumed no slot.
    # Pre-fix VBox placed the label in slot 0 and pushed c1 down a third.
    c1.lpos.not_nil!.yi.should eq interior_top
    # Two children split the interior; neither is starved to nothing.
    c1.lpos.not_nil!.yl.should be > c1.lpos.not_nil!.yi
    c2.lpos.not_nil!.yl.should be > c2.lpos.not_nil!.yi
    # c2 reaches the interior bottom (only two slots, not three).
    c2.lpos.not_nil!.yl.should eq(bl.yl - box.ibottom)
  end

  it "does not let a shown scroll bar starve content children under a VBox" do
    s = headless_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 30, height: 12,
      scrollable: true, layout: Layout::VBox.new
    box.scrollbar_policy = Widget::ScrollBarPolicy::AlwaysOn

    c1 = Widget::Box.new parent: box
    c2 = Widget::Box.new parent: box

    s._render

    sb = box.scrollbar_widget.not_nil!
    sb.layout_chrome?.should be_true
    sb.right.should eq 0 # pinning preserved, not overwritten to a slot

    # Pre-fix the vertical bar (height "100%") consumed the whole interior in
    # Box#measure, starving the flex children to height 0. Post-fix both keep
    # real height.
    c1.lpos.not_nil!.yl.should be > c1.lpos.not_nil!.yi
    c2.lpos.not_nil!.yl.should be > c2.lpos.not_nil!.yi
  end
end

# BUGS15 #54 — `scrollable` was a bare `property?`. The content-clamp handler
# (`Event::ParsedContent → _recalculate_index`) is wired only in the constructor
# and only for a widget built `scrollable: true`. A widget flipped scrollable at
# runtime never got it, so a later content shrink left `@child_base` past the
# content and the viewport rendered blank. The custom setter now wires it once.
describe "BUGS15 54: runtime scrollable= wires the content-clamp handler" do
  it "clamps child_base when content shrinks after a runtime scrollable flip" do
    s = headless_screen
    box = Widget::Box.new parent: s, width: 10, height: 5
    box.scrollable = true # runtime flip

    box.set_content(Array.new(20) { |i| "line #{i}" }.join("\n"))
    box.scroll(15)
    box.child_base.should be > 0 # scrolled down into the content

    # Content shrinks to a single line: the clamp handler must pull child_base
    # back to 0 so the line stays visible. Pre-fix child_base stayed stuck.
    box.set_content("only one line")
    box.child_base.should eq 0
  end

  it "matches a constructor-scrollable widget's clamp behavior" do
    s = headless_screen
    box = Widget::Box.new parent: s, width: 10, height: 5, scrollable: true

    box.set_content(Array.new(20) { |i| "line #{i}" }.join("\n"))
    box.scroll(15)
    box.set_content("only one line")
    box.child_base.should eq 0
  end

  it "does not double-wire when set to the same value" do
    s = headless_screen
    box = Widget::Box.new parent: s, width: 10, height: 5
    box.scrollable = true
    n = box.handlers(Crysterm::Event::ParsedContent).size
    box.scrollable = true # redundant: must not add another handler
    box.handlers(Crysterm::Event::ParsedContent).size.should eq n
  end
end

# BUGS15 #55 — vertical bar (`height: "100%"`) and horizontal bar
# (`width: "100%"`) both claimed the bottom-right corner cell; the second-drawn
# bar overpainted the other's last cell and stole corner clicks. The fix shortens
# each bar by the other's extent in `update_scrollbar_widget`, reserving the
# corner (Qt's `QAbstractScrollArea` corner).
describe "BUGS15 55: scroll bars reserve the bottom-right corner" do
  it "shortens each bar by the other when both are shown" do
    s = headless_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 8,
      scrollable: true
    box.scrollbar_policy = Widget::ScrollBarPolicy::AlwaysOn
    box.horizontal_scrollbar_policy = Widget::ScrollBarPolicy::AlwaysOn

    s._render

    vb = box.scrollbar_widget.not_nil!
    hb = box.horizontal_scrollbar_widget.not_nil!

    # Corner reserved: vertical bar loses the horizontal bar's row, and vice
    # versa, so they never overlap in the corner cell.
    vb.height.should eq "100%-#{box.scrollbar_height}"
    hb.width.should eq "100%-#{box.scrollbar_width}"
  end

  it "uses full extent when only one bar is shown" do
    s = headless_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 8,
      scrollable: true
    box.scrollbar_policy = Widget::ScrollBarPolicy::AlwaysOn
    # horizontal stays AlwaysOff (default)

    s._render

    vb = box.scrollbar_widget.not_nil!
    vb.height.should eq "100%" # no horizontal bar → no corner reservation
  end
end
