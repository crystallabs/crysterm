require "./spec_helper"

include Crysterm

# Specs for the §5.2/§5.3/§5.4 style & CSS API polish: box-value shorthand
# parity and named constructors, `color`/`background_color` aliases,
# copy-on-write per-state styles + the `checked` slot, sub-style `?` readers,
# `repaints_every_frame`, CSS geometry snapshot auto-folding, `display:`
# layout installation, and per-widget stylesheets.

private def damage_screen(w = 30, h = 8, optimization = Crysterm::OptimizationFlag::DamageTracking)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false, optimization: optimization)
end

# Counts its own `#paint` calls.
private class PaintProbe < Crysterm::Widget::Box
  property paints = 0

  def paint(*, with_children = true)
    @paints += 1
    super
  end
end

describe "box value shorthand parity (Border/Shadow tuples, named constructors)" do
  it "accepts CSS tuple shorthands for border and shadow in Style.new" do
    st = Style.new(border: {1, 2}, shadow: {0, 1, 2, 3})
    # {v, h}: top/bottom 1, left/right 2.
    st.border.top.should eq 1
    st.border.bottom.should eq 1
    st.border.left.should eq 2
    st.border.right.should eq 2
    # {t, r, b, l} clockwise from top.
    st.shadow.top.should eq 0
    st.shadow.right.should eq 1
    st.shadow.bottom.should eq 2
    st.shadow.left.should eq 3
  end

  it "builds boxes via the order-named constructors" do
    p = Padding.trbl(1, 2, 3, 4)
    {p.left, p.top, p.right, p.bottom}.should eq({4, 1, 2, 3})
    m = Margin.vh(1, 2)
    {m.left, m.top, m.right, m.bottom}.should eq({2, 1, 2, 1})
    b = Border.trbl(1, 2, 3, 4)
    {b.left, b.top, b.right, b.bottom}.should eq({4, 1, 2, 3})
    sh = Shadow.vh(1, 2)
    {sh.left, sh.top, sh.right, sh.bottom}.should eq({2, 1, 2, 1})
  end

  it "builds boxes via the per-side named constructors" do
    p = Padding.left(2)
    {p.left, p.top, p.right, p.bottom}.should eq({2, 0, 0, 0})
    m = Margin.horizontal(3)
    {m.left, m.top, m.right, m.bottom}.should eq({3, 0, 3, 0})
    b = Border.right
    {b.left, b.top, b.right, b.bottom}.should eq({0, 0, 1, 0})
    a = Margin.all(2)
    {a.left, a.top, a.right, a.bottom}.should eq({2, 2, 2, 2})
  end
end

describe "Style color/background_color aliases" do
  it "reads and writes the same values as fg/bg" do
    st = Style.new(fg: "white", bg: 0x123456)
    st.color.should eq st.fg
    st.background_color.should eq 0x123456
    st.color = 0xAB0012
    st.fg.should eq 0xAB0012
    st.background_color = "red"
    st.bg.should eq rgb("red")
    st.background_color = nil
    st.bg.should be_nil
  end

  it "advances attr_revision like the underlying setters" do
    st = Style.new
    before = st.attr_revision
    st.color = "blue"
    st.attr_revision.should be > before
  end
end

describe "Styles copy-on-write per-state slots" do
  it "materializes an own state style instead of mutating normal" do
    styles = Styles.new
    styles.own_focused?.should be_false
    styles.focused.bg = 0xFF0000
    styles.own_focused?.should be_true
    styles.normal.bg.should be_nil
    styles.focused.bg.should eq 0xFF0000
  end

  it "keeps #[] non-materializing (falls back to normal)" do
    styles = Styles.new
    styles[WidgetState::Focused].same?(styles.normal).should be_true
    styles.own_focused?.should be_false
  end

  it "deep_dup copies the checked slot" do
    styles = Styles.new
    styles.checked.bg = 0x00FF00
    copy = styles.deep_dup
    copy.own_checked?.should be_true
    copy.checked.same?(styles.checked).should be_false
    copy.checked.bg.should eq 0x00FF00
  end
end

describe "Styles#checked programmatic slot" do
  it "styles a checked control at the unstyled floor" do
    s = headless_screen(40, 8)
    cb = Widget::CheckBox.new parent: s, text: "opt"
    cb.styles.checked = Style.new(bg: 0x220044)
    s.repaint
    cb.style.bg.should be_nil
    cb.checked = true
    cb.style.bg.should eq 0x220044
    cb.checked = false
    cb.style.bg.should be_nil
  end

  it "yields to an explicitly-set current-state slot" do
    s = headless_screen(40, 8)
    cb = Widget::CheckBox.new parent: s, text: "opt"
    cb.styles.checked = Style.new(bg: 0x220044)
    cb.styles.selected = Style.new(bg: 0x005500)
    cb.checked = true
    cb.state = WidgetState::Selected
    cb.style.bg.should eq 0x005500
    # A state with no own slot falls back to the checked style.
    cb.state = WidgetState::Hovered
    cb.style.bg.should eq 0x220044
  end
end

describe "Style sub-style ? readers" do
  it "reports only an explicitly-assigned sub-style" do
    st = Style.new
    st.title?.should be_nil
    st.title.same?(st).should be_true # fallback getter unchanged
    st.title = Style.new(fg: "red")
    st.title?.try(&.fg).should eq rgb("red")
    st.title.same?(st).should be_false
  end
end

describe "Widget#repaints_every_frame under damage tracking" do
  it "repaints the opted-in widget every selective frame, others stay carried" do
    s = damage_screen(40, 10)
    animated = PaintProbe.new parent: s, top: 1, left: 1, width: 8, height: 2, content: "anim"
    animated.repaints_every_frame = true
    static = PaintProbe.new parent: s, top: 6, left: 20, width: 8, height: 2, content: "still"

    s.repaint # first frame: full composite, both paint
    animated.paints.should eq 1
    static.paints.should eq 1

    s.repaint # selective: only the opted-in widget repaints
    animated.paints.should eq 2
    static.paints.should eq 1
  end
end

describe "CSS geometry snapshot auto-folding" do
  it "keeps a programmatic write as the new pre-CSS baseline" do
    s = headless_screen(60, 20)
    box = Widget::Box.new parent: s, width: 10, height: 3
    without_default_theme do
      s.stylesheet = "Box { width: 30 }"
      s.apply_stylesheet
      box.width.should eq 30

      # Programmatic write while CSS geometry is active: becomes the baseline.
      box.height = 5

      s.stylesheet = nil
      s.apply_stylesheet
      # CSS-written width reverted to pristine; programmatic height kept.
      box.width_spec.should eq 10
      box.height_spec.should eq 5
    end
  end
end

describe "CSS display: installs layout engines" do
  it "installs a vertical Layout::Box for display: flex + flex-direction: column" do
    s = headless_screen(60, 20)
    box = Widget::Box.new parent: s, width: 30, height: 10
    Widget::Box.new parent: box
    Widget::Box.new parent: box
    without_default_theme do
      s.stylesheet = "Box { display: flex; flex-direction: column; }"
      s.apply_stylesheet
      engine = box.layout
      engine.is_a?(Layout::Box).should be_true
      engine.as(Layout::Box).orientation.vertical?.should be_true
    end
  end

  it "installs Layout::Grid with the grid-template-columns track count" do
    s = headless_screen(60, 20)
    box = Widget::Box.new parent: s, width: 30, height: 10
    without_default_theme do
      s.stylesheet = "Box { display: grid; grid-template-columns: 1fr 1fr 1fr; }"
      s.apply_stylesheet
      engine = box.layout
      engine.is_a?(Layout::Grid).should be_true
      engine.as(Layout::Grid).columns.should eq 3
    end
  end

  it "restores the pre-CSS engine when the rule goes away" do
    s = headless_screen(60, 20)
    box = Widget::Box.new parent: s, width: 30, height: 10
    without_default_theme do
      s.stylesheet = "Box { display: flex; }"
      s.apply_stylesheet
      box.layout.is_a?(Layout::Box).should be_true
      s.stylesheet = nil
      s.apply_stylesheet
      box.layout.nil?.should be_true
    end
  end
end

describe "per-widget stylesheets" do
  it "scopes a widget's own sheet to its subtree and outranks window author rules" do
    s = headless_screen(60, 20)
    themed = Widget::Box.new parent: s, width: 10, height: 3
    child = Widget::Box.new parent: themed
    plain = Widget::Box.new parent: s, top: 5, width: 10, height: 3
    without_default_theme do
      s.stylesheet = "Box { background-color: blue }"
      themed.stylesheet = "Box { background-color: red }"
      s.apply_stylesheet
      themed.styles.normal.bg.should eq rgb("red")
      child.styles.normal.bg.should eq rgb("red")
      plain.styles.normal.bg.should eq rgb("blue")
    end
  end

  it "composes with add_stylesheet, later sheet winning ties" do
    s = headless_screen(60, 20)
    box = Widget::Box.new parent: s, width: 10, height: 3
    without_default_theme do
      box.stylesheet = "Box { background-color: red; color: white }"
      box.add_stylesheet "Box { background-color: green }"
      s.apply_stylesheet
      box.styles.normal.bg.should eq rgb("green")
      box.styles.normal.fg.should eq rgb("white")
    end
  end

  it "clears back to the window rules when the widget sheet is removed" do
    s = headless_screen(60, 20)
    box = Widget::Box.new parent: s, width: 10, height: 3
    without_default_theme do
      s.stylesheet = "Box { background-color: blue }"
      box.stylesheet = "Box { background-color: red }"
      s.apply_stylesheet
      box.styles.normal.bg.should eq rgb("red")
      box.stylesheet = nil
      s.apply_stylesheet
      box.styles.normal.bg.should eq rgb("blue")
    end
  end

  it "activates CSS with only a widget sheet (no window sheet)" do
    s = headless_screen(60, 20)
    box = Widget::Box.new parent: s, width: 10, height: 3
    without_default_theme do
      box.stylesheet = "Box { background-color: red }"
      s.apply_stylesheet
      box.styles.normal.bg.should eq rgb("red")
      box.css_styled?.should be_true
    end
  end
end

describe "Window#add_stylesheet composition" do
  it "layers added sheets over the main author sheet" do
    s = headless_screen(60, 20)
    box = Widget::Box.new parent: s, width: 10, height: 3
    without_default_theme do
      s.stylesheet = "Box { background-color: blue; color: white }"
      s.add_stylesheet "Box { background-color: green }"
      s.apply_stylesheet
      box.styles.normal.bg.should eq rgb("green")
      box.styles.normal.fg.should eq rgb("white")
    end
  end
end
