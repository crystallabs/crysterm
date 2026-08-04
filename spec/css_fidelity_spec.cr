require "./spec_helper"

include Crysterm

# Border side colors for a mid-grey `border-style: <style>` box, so both shading
# directions are visible against the base color.
private def shaded(style : String) : {Int32?, Int32?}
  screen = headless_screen
  box = Crysterm::Widget::Box.new width: 10, height: 3
  screen.append box
  screen.stylesheet = "Box { border: solid #808080; border-style: #{style}; }"
  screen.apply_stylesheet
  b = box.style.border
  {b.side_fg(Crysterm::Side::Top, nil), b.side_fg(Crysterm::Side::Bottom, nil)}
end

# A child of a laid-out parent, styled with `position: <value>`.
private def positioned(value : String) : Crysterm::Widget
  screen = headless_screen
  parent = Crysterm::Widget::Box.new width: 30, height: 8, layout: Crysterm::Layout::VBox.new
  child = Crysterm::Widget::Box.new width: 5, height: 1
  screen.append parent
  parent.append child
  screen.stylesheet = "Box > Box { position: #{value}; }"
  screen.apply_stylesheet
  child
end

# Behavior lock for the CSS-fidelity work: properties whose Crysterm handling
# used to diverge from what the CSS/QSS spelling means, plus the CSS-native
# spellings added alongside the pre-existing Crysterm-only ones.
describe "CSS fidelity" do
  describe "text-align / vertical-align" do
    it "replaces only the horizontal bits, leaving vertical alignment intact" do
      screen = headless_screen
      box = Widget::Box.new align: Tput::AlignFlag::VCenter, width: 10, height: 3
      screen.append box

      screen.stylesheet = "Box { text-align: center; }"
      screen.apply_stylesheet

      box.align.h_center?.should be_true
      box.align.v_center?.should be_true
    end

    it "sets the vertical axis from vertical-align without touching the horizontal" do
      screen = headless_screen
      box = Widget::Box.new align: Tput::AlignFlag::Right, width: 10, height: 3
      screen.append box

      screen.stylesheet = "Box { vertical-align: bottom; }"
      screen.apply_stylesheet

      box.align.bottom?.should be_true
      box.align.right?.should be_true
    end

    it "accepts middle and center as the same vertical keyword" do
      Crysterm::TextAlign.valign_flag("middle").should eq Tput::AlignFlag::VCenter
      Crysterm::TextAlign.valign_flag("center").should eq Tput::AlignFlag::VCenter
      Crysterm::TextAlign.valign_flag("nonsense").should be_nil
    end
  end

  describe "gap" do
    it "accepts CSS gap as a synonym of Qt's spacing" do
      {"gap: 3", "spacing: 3"}.each do |decl|
        screen = headless_screen
        box = Widget::Box.new width: 20, height: 6, layout: Layout::VBox.new
        screen.append box

        screen.stylesheet = "Box { #{decl}; }"
        screen.apply_stylesheet

        box.layout.try(&.spacing).should eq 3
      end
    end

    it "resolves a unit'd gap through the length table, not just a bare integer" do
      screen = headless_screen
      box = Widget::Box.new width: 20, height: 6, layout: Layout::VBox.new
      screen.append box

      screen.stylesheet = "Box { gap: 2em; }"
      screen.apply_stylesheet

      box.layout.try(&.spacing).should eq 2
    end
  end

  describe "inherited properties" do
    it "inherits tab-size down the tree, as CSS does" do
      screen = headless_screen
      parent = Widget::Box.new width: 20, height: 6
      child = Widget::Box.new width: 10, height: 1
      screen.append parent
      parent.append child

      screen.stylesheet = "Box { tab-size: 7; }"
      screen.apply_stylesheet

      parent.style.tab_size.should eq 7
      child.style.tab_size.should eq 7
    end

    it "lets an explicit child value win over the inherited one" do
      screen = headless_screen
      parent = Widget::Box.new width: 20, height: 6
      child = Widget::Box.new width: 10, height: 1
      child.add_css_class "narrow"
      screen.append parent
      parent.append child

      screen.stylesheet = "Box { tab-size: 7; } .narrow { tab-size: 2; }"
      screen.apply_stylesheet

      child.style.tab_size.should eq 2
    end
  end

  describe "min-/max- percentages" do
    it "resolves a percentage constraint against the parent's content area" do
      screen = headless_screen
      parent = Widget::Box.new width: 30, height: 10
      child = Widget::Box.new width: 30, height: 1
      child.add_css_class "half"
      screen.append parent
      parent.append child

      screen.stylesheet = ".half { max-width: 50%; }"
      screen.apply_stylesheet

      child.resolved_max_width.should eq 15
      child.awidth.should eq 15
    end

    it "re-resolves the percentage when the parent resizes" do
      screen = headless_screen
      parent = Widget::Box.new width: 30, height: 10
      child = Widget::Box.new width: 30, height: 1
      child.add_css_class "half"
      screen.append parent
      parent.append child

      screen.stylesheet = ".half { max-width: 50%; }"
      screen.apply_stylesheet
      child.awidth.should eq 15

      parent.width = 20
      child.awidth.should eq 10
    end

    it "keeps min winning over max, per CSS" do
      screen = headless_screen
      parent = Widget::Box.new width: 30, height: 10
      child = Widget::Box.new width: 30, height: 1
      child.add_css_class "c"
      screen.append parent
      parent.append child

      screen.stylesheet = ".c { min-width: 8; max-width: 4; }"
      screen.apply_stylesheet

      child.awidth.should eq 8
    end

    it "clears the constraint on `none`" do
      screen = headless_screen
      box = Widget::Box.new width: 30, height: 1
      box.max_width = 5
      screen.append box
      box.awidth.should eq 5

      screen.stylesheet = "Box { max-width: none; }"
      screen.apply_stylesheet

      box.max_width.should be_nil
      box.awidth.should eq 30
    end

    it "still accepts a plain cell count" do
      screen = headless_screen
      box = Widget::Box.new width: 30, height: 1
      screen.append box

      screen.stylesheet = "Box { max-width: 6; }"
      screen.apply_stylesheet

      box.max_width.should eq 6
      box.awidth.should eq 6
    end
  end

  describe "border-style" do
    it "darkens the near edges and lightens the far ones for inset/groove" do
      {"inset", "groove"}.each do |style|
        top, bottom = shaded style
        top.should_not be_nil
        top.not_nil!.should be < 0x808080
        bottom.not_nil!.should be > 0x808080
      end
    end

    it "reverses the shading for outset/ridge" do
      {"outset", "ridge"}.each do |style|
        top, bottom = shaded style
        top.not_nil!.should be > 0x808080
        bottom.not_nil!.should be < 0x808080
      end
    end

    it "leaves a flat style unshaded and clears a relief set by a previous rule" do
      top, bottom = shaded "solid"
      top.should eq 0x808080
      bottom.should eq 0x808080
    end

    it "keeps an explicit per-side color out of the shading" do
      screen = headless_screen
      box = Widget::Box.new width: 10, height: 3
      screen.append box
      screen.stylesheet = "Box { border: solid #808080; border-style: inset; border-top-color: #ff0000; }"
      screen.apply_stylesheet

      box.style.border.side_fg(Crysterm::Side::Top, nil).should eq 0xff0000
    end

    it "treats `hidden` like `none`" do
      screen = headless_screen
      box = Widget::Box.new width: 10, height: 3
      screen.append box
      screen.stylesheet = "Box { border: solid red; border-style: hidden; }"
      screen.apply_stylesheet

      b = box.style.border
      {b.left, b.top, b.right, b.bottom}.should eq({0, 0, 0, 0})
    end

    it "treats a `hidden` token in the `border` shorthand like `none`, whatever the order" do
      {"border: 2 hidden red", "border: hidden 2 red"}.each do |decl|
        screen = headless_screen
        box = Widget::Box.new width: 10, height: 3
        screen.append box
        screen.stylesheet = "Box { #{decl}; }"
        screen.apply_stylesheet

        b = box.style.border
        {b.left, b.top, b.right, b.bottom}.should eq({0, 0, 0, 0})
      end
    end
  end

  describe "border width" do
    # The `border` / `border-<side>` shorthands and the `border-width` /
    # `border-<side>-width` longhands share one resolver, so they must agree.
    it "resolves a sub-cell hairline to no border in every spelling" do
      {"border: 1px solid red", "border-width: 1px",
       "border-left: 1px solid red", "border-left-width: 1px"}.each do |decl|
        screen = headless_screen
        box = Widget::Box.new width: 10, height: 3
        screen.append box
        screen.stylesheet = "Box { border: solid; #{decl}; }"
        screen.apply_stylesheet

        box.style.border.left.should eq 0
      end
    end

    it "honors a width that reaches a whole cell in every spelling" do
      {"border: 2 solid red", "border-width: 2",
       "border-left: 2 solid red", "border-left-width: 2"}.each do |decl|
        screen = headless_screen
        box = Widget::Box.new width: 10, height: 3
        screen.append box
        screen.stylesheet = "Box { border: solid; #{decl}; }"
        screen.apply_stylesheet

        box.style.border.left.should eq 2
      end
    end

    it "keeps the named widths, which are stated in cell-scale terms" do
      screen = headless_screen
      box = Widget::Box.new width: 10, height: 3
      screen.append box
      screen.stylesheet = "Box { border: thick solid red; }"
      screen.apply_stylesheet

      box.style.border.left.should eq 2
    end
  end

  describe "position" do
    it "takes an absolute widget out of the layout flow but keeps it painted" do
      child = positioned "absolute"
      child.layout_chrome?.should be_true
      child.fixed?.should be_false
      child.layout_excluded?.should be_false
    end

    it "additionally pins a fixed widget against scrolling" do
      child = positioned "fixed"
      child.layout_chrome?.should be_true
      child.fixed?.should be_true
    end

    it "leaves a static (or relative) widget in the flow" do
      {"static", "relative"}.each do |value|
        child = positioned value
        child.layout_chrome?.should be_false
        child.fixed?.should be_false
      end
    end

    it "reverts to the pristine value when the rule stops matching" do
      screen = headless_screen
      parent = Widget::Box.new width: 30, height: 8, layout: Layout::VBox.new
      child = Widget::Box.new width: 5, height: 1
      child.add_css_class "floaty"
      screen.append parent
      parent.append child

      screen.stylesheet = ".floaty { position: absolute; }"
      screen.apply_stylesheet
      child.layout_chrome?.should be_true

      screen.stylesheet = ".nothing { position: absolute; }"
      screen.apply_stylesheet
      child.layout_chrome?.should be_false
    end
  end

  describe "content" do
    it "accepts CSS content as a synonym of the glyph property" do
      {"content", "glyph"}.each do |property|
        screen = headless_screen
        box = Widget::CheckBox.new width: 10, height: 1, content: "a"
        screen.append box

        screen.stylesheet = "CheckBox::indicator { #{property}: \"x\"; }"
        screen.apply_stylesheet

        box.style.indicator.glyph.should eq "x"
      end
    end
  end

  describe "box-sizing" do
    it "defaults to border-box: the declared size is the whole widget" do
      screen = headless_screen
      box = Widget::Box.new width: 10, height: 5
      screen.append box
      screen.stylesheet = "Box { border: solid; padding: 1; }"
      screen.apply_stylesheet
      screen.repaint

      box.box_sizing.border_box?.should be_true
      box.awidth.should eq 10
      box.aheight.should eq 5
      # Border + padding eat inward, leaving 10-4 x 5-4 of content.
      (box.awidth - box.ihorizontal).should eq 6
      (box.aheight - box.ivertical).should eq 1
    end

    it "adds the frame outside the declared size under content-box, as CSS does" do
      screen = headless_screen
      box = Widget::Box.new width: 10, height: 5
      screen.append box
      screen.stylesheet = "Box { border: solid; padding: 1; box-sizing: content-box; }"
      screen.apply_stylesheet
      screen.repaint

      box.box_sizing.content_box?.should be_true
      box.awidth.should eq 14 # 10 content + 2 border + 2 padding
      box.aheight.should eq 9
      (box.awidth - box.ihorizontal).should eq 10 # content is what was declared
      (box.aheight - box.ivertical).should eq 5
    end

    it "gives a bordered one-row widget a complete frame instead of dropping it" do
      screen = headless_screen
      box = Widget::Box.new width: 20, height: 1
      box.add_css_class "cb"
      screen.append box
      screen.stylesheet = "Box { border: solid; } .cb { box-sizing: content-box; }"
      screen.apply_stylesheet
      screen.repaint

      box.aheight.should eq 3 # 1 content row + top and bottom edges
      screen.lines[0][0].char.should eq '┌'
      screen.lines[2][0].char.should eq '└'
    end

    it "applies min-/max- to the same box the size measures, per CSS" do
      screen = headless_screen
      box = Widget::Box.new width: 10, height: 3
      screen.append box
      screen.stylesheet = "Box { border: solid; box-sizing: content-box; max-width: 6; }"
      screen.apply_stylesheet
      screen.repaint

      # The cap applies to the content box (10 -> 6), then the frame is added.
      box.awidth.should eq 8
    end

    it "leaves an auto size alone (it fills its slot as a whole box)" do
      screen = headless_screen(40, 10)
      box = Widget::Box.new
      screen.append box
      screen.stylesheet = "Box { border: solid; box-sizing: content-box; }"
      screen.apply_stylesheet
      screen.repaint

      box.awidth.should eq 40
      box.aheight.should eq 10
    end

    it "reverts to the pristine value when the rule stops matching" do
      screen = headless_screen
      box = Widget::Box.new width: 10, height: 5
      box.add_css_class "cb"
      screen.append box
      screen.stylesheet = ".cb { box-sizing: content-box; border: solid; }"
      screen.apply_stylesheet
      box.awidth.should eq 12

      screen.stylesheet = ".nothing { box-sizing: content-box; }"
      screen.apply_stylesheet
      box.box_sizing.border_box?.should be_true
    end
  end

  describe "border end caps" do
    # A border needs both of an axis' edges plus nothing else to be drawable; a
    # box too small for that drops that axis (see `Widget#effective_insets`).
    # The surviving perpendicular pair then has no corners to close it, so it
    # draws with cap glyphs rather than the line-family runs, which imply corners.
    it "caps the left/right edges of a one-row box" do
      screen = headless_screen
      box = Widget::Box.new width: 12, height: 1
      screen.append box
      screen.stylesheet = "Box { border: solid; }"
      screen.apply_stylesheet
      screen.repaint

      screen.lines[0][0].char.should eq '█'
      screen.lines[0][11].char.should eq '█'
    end

    it "caps the top/bottom edges of a one-column box" do
      screen = headless_screen
      box = Widget::Box.new width: 1, height: 4
      screen.append box
      screen.stylesheet = "Box { border: solid; }"
      screen.apply_stylesheet
      screen.repaint

      screen.lines[0][0].char.should eq '█'
      screen.lines[3][0].char.should eq '█'
    end

    it "draws the ordinary full frame when the border fits" do
      screen = headless_screen
      box = Widget::Box.new width: 12, height: 3
      screen.append box
      screen.stylesheet = "Box { border: solid; }"
      screen.apply_stylesheet
      screen.repaint

      screen.lines[0][0].char.should eq '┌'
      screen.lines[1][0].char.should eq '│'
      screen.lines[2][0].char.should eq '└'
    end

    it "lets an explicit border char override outrank the cap" do
      screen = headless_screen
      box = Widget::Box.new width: 12, height: 1
      screen.append box
      screen.stylesheet = "Box { border: solid; border-left-char: \"@\"; }"
      screen.apply_stylesheet
      screen.repaint

      screen.lines[0][0].char.should eq '@'  # author's choice
      screen.lines[0][11].char.should eq '█' # uncustomized side still caps
    end

    it "uses the ascii solid at the ascii tier, which has no block glyph" do
      {Glyphs::Role::BorderCapLeft, Glyphs::Role::BorderCapRight,
       Glyphs::Role::BorderCapTop, Glyphs::Role::BorderCapBottom}.each do |role|
        Glyphs[role, Glyphs::Tier::Ascii].should eq '#'
        Glyphs[role, Glyphs::Tier::Unicode].should eq '█'
      end
    end
  end

  describe "quotes" do
    it "sets the delimiter pair, like the glyph-open/glyph-close longhands" do
      screen = headless_screen
      box = Widget::CheckBox.new width: 10, height: 1, content: "a"
      screen.append box

      screen.stylesheet = "CheckBox::indicator { quotes: \"[\" \"]\"; }"
      screen.apply_stylesheet

      box.style.indicator.glyph_open.should eq "["
      box.style.indicator.glyph_close.should eq "]"
    end

    it "clears both halves on `none`" do
      screen = headless_screen
      box = Widget::CheckBox.new width: 10, height: 1, content: "a"
      screen.append box

      screen.stylesheet = "CheckBox::indicator { glyph-open: \"[\"; glyph-close: \"]\"; quotes: none; }"
      screen.apply_stylesheet

      box.style.indicator.glyph_open.should be_nil
      box.style.indicator.glyph_close.should be_nil
    end

    it "drops a malformed value rather than setting half a pair" do
      screen = headless_screen
      box = Widget::CheckBox.new width: 10, height: 1, content: "a"
      screen.append box

      screen.stylesheet = "CheckBox::indicator { glyph-open: \"(\"; glyph-close: \")\"; quotes: \"[\"; }"
      screen.apply_stylesheet

      box.style.indicator.glyph_open.should eq "("
      box.style.indicator.glyph_close.should eq ")"
    end
  end
end
