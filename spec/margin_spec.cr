require "./spec_helper"

include Crysterm

# `margin` is the element's own outer spacing, the mirror of `padding`/`border`
# (inner insets), and outward like CSS: a fixed-size element keeps its size and
# is pushed away from its anchored edge, reserving empty space around it,
# without touching inner content offsets (`ileft` & co.). Specs assert the
# resolved rectangle (`_get_coords`/`lpos`), content preservation, CSS parsing,
# and sibling spacing.

private def render_screen
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 80, height: 24)
end

private def headless_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
end

describe "margin" do
  describe "Margin struct" do
    it "parses from shorthand values like padding" do
      Margin.from(nil).any?.should be_false
      Margin.from(false).any?.should be_false
      Margin.from(true).left.should eq 1
      m = Margin.from(2)
      {m.left, m.top, m.right, m.bottom}.should eq({2, 2, 2, 2})
    end

    # `Margin`/`Padding` are mutated in place by per-side longhands, so the
    # default must never be a shared singleton, or one style's edit leaks into
    # every other style.
    it "gives each style an independent margin/padding (no shared default)" do
      a = Style.new
      b = Style.new
      a.margin.same?(b.margin).should be_false
      a.padding.same?(b.padding).should be_false

      a.margin.left = 5
      a.padding.top = 7
      b.margin.left.should eq 0
      b.padding.top.should eq 0
      Margin.default.left.should eq 0
      Padding.default.top.should eq 0
    end

    # An invalid `margin`/`padding` shorthand resets the side to a fresh zero
    # box; a following longhand must edit that style's own box, not the default.
    it "doesn't corrupt the default when an invalid shorthand precedes a longhand" do
      s = Style.new
      Crysterm::CSS::Properties.apply s, "margin", "1 2 3 4 5" # over-long → invalid
      Crysterm::CSS::Properties.apply s, "margin-top", "3"
      s.margin.top.should eq 3
      Margin.default.top.should eq 0
      Style.new.margin.top.should eq 0
    end
  end

  describe "geometry" do
    # Pre-cascade: `style` short-circuits to the inline `@style`, exercising the
    # inline constructor + `_get_coords` inset directly, without CSS in between.
    it "shifts a fixed-size widget by its margin, keeping its size (inline)" do
      screen = render_screen
      plain = Widget::Box.new parent: screen, top: 1, left: 2, width: 10, height: 5
      boxed = Widget::Box.new parent: screen, top: 1, left: 2, width: 10, height: 5,
        style: Style.new(margin: 1)

      pl = plain._get_coords.not_nil!
      bx = boxed._get_coords.not_nil!

      # Plain box occupies its full slot.
      {pl.xi, pl.xl, pl.yi, pl.yl}.should eq({2, 12, 1, 6})
      # Margin 1 pushes the (left/top-anchored) box in by 1 on the near edges,
      # keeping its 10x5 size — the margin reserves space outside it.
      {bx.xi, bx.xl, bx.yi, bx.yl}.should eq({3, 13, 2, 7})
    end

    it "honors asymmetric per-side margins (inline)" do
      screen = render_screen
      box = Widget::Box.new parent: screen, top: 0, left: 0, width: 20, height: 10,
        style: Style.new(margin: Margin.new(left: 1, top: 2, right: 3, bottom: 4))

      l = box._get_coords.not_nil!
      # Left/top-anchored: only the near (left/top) margins shift the box; the
      # far (right/bottom) margins reserve space outside, keeping the 20x10 size.
      {l.xi, l.xl, l.yi, l.yl}.should eq({0 + 1, 20 + 1, 0 + 2, 10 + 2})
    end

    # Full pipeline: margin via CSS rule, folded by the cascade, applied at
    # render — `lpos` carries the same inset.
    it "applies a CSS margin at render time" do
      screen = render_screen
      box = Widget::Box.new parent: screen, top: 1, left: 2, width: 10, height: 5
      screen.stylesheet = "Box { margin: 1; }"
      screen._render

      l = box.lpos.not_nil!
      {l.xi, l.xl, l.yi, l.yl}.should eq({3, 13, 2, 7})
    end

    it "leaves the inner content offsets (border/padding) untouched" do
      screen = render_screen
      box = Widget::Box.new parent: screen, top: 0, left: 0, width: 20, height: 10
      box.add_css_class "deco"
      screen.stylesheet = ".deco { border: solid; padding: 1; margin: 2; }"
      screen._render

      # i* are inner offsets: border(1) + padding(1) = 2 per side, regardless of
      # margin. m* are the separate outer offsets.
      box.ileft.should eq 2
      box.iwidth.should eq 4
      box.mleft.should eq 2
      box.mwidth.should eq 4
    end
  end

  describe "shrink-to-content" do
    it "reserves room so a margin never clips a content-sized widget" do
      screen = render_screen
      plain = Widget::Box.new parent: screen, top: 0, left: 0, content: "hello"
      plain.resizable = true
      boxed = Widget::Box.new parent: screen, top: 0, left: 0, content: "hello"
      boxed.resizable = true
      boxed.add_css_class "m"
      screen.stylesheet = ".m { margin: 1; }"
      screen._render

      pl = plain.lpos.not_nil!
      bx = boxed.lpos.not_nil!

      # Both fit the 5-cell content; the margined one is shifted, not clipped.
      (pl.xl - pl.xi).should eq(bx.xl - bx.xi)
      (pl.yl - pl.yi).should eq(bx.yl - bx.yi)
      bx.xi.should eq pl.xi + 1
      bx.yi.should eq pl.yi + 1
    end
  end

  describe "CSS" do
    it "parses the margin shorthand (TRBL) onto the style" do
      screen = headless_screen
      box = Widget::Box.new
      screen.append box

      screen.stylesheet = "Box { margin: 1 2 3 4; }"
      screen.apply_stylesheet

      m = box.styles.normal.margin
      {m.top, m.right, m.bottom, m.left}.should eq({1, 2, 3, 4})
    end

    it "parses per-side margin longhands" do
      screen = headless_screen
      box = Widget::Box.new
      screen.append box

      screen.stylesheet = "Box { margin-left: 5; margin-top: 6; margin-right: 7; margin-bottom: 8; }"
      screen.apply_stylesheet

      m = box.styles.normal.margin
      {m.left, m.top, m.right, m.bottom}.should eq({5, 6, 7, 8})
    end

    it "treats margin as a known property" do
      Crysterm::CSS::Properties.known?("margin").should be_true
      Crysterm::CSS::Properties.known?("margin-left").should be_true
    end

    it "lets an inline margin switch off over a stylesheet via the cascade" do
      screen = headless_screen
      box = Widget::Box.new parent: screen, style: Style.new(margin: 2)
      screen.stylesheet = "Box { color: white; }"
      screen.apply_stylesheet

      # Inline margin folds into the computed normal style.
      box.styles.normal.margin.left.should eq 2
    end
  end

  describe "layout spacing" do
    it "separates HBox children by their adjacent margins" do
      screen = render_screen
      box = Widget::Box.new parent: screen, top: 0, left: 0, width: 40, height: 6,
        layout: Layout::Box.new(orientation: Layout::Box::Orientation::Horizontal)
      a = Widget::Box.new parent: box, width: 8, height: 4
      b = Widget::Box.new parent: box, width: 8, height: 4
      b.add_css_class "ml"
      screen.stylesheet = ".ml { margin-left: 2; }"
      screen._render

      la = a.lpos.not_nil!
      lb = b.lpos.not_nil!
      # b's left margin opens a 2-cell gap after a's drawn right edge.
      (lb.xi - la.xl).should eq 2
    end
  end
end
