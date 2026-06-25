require "./spec_helper"

include Crysterm

private def render_screen
  Crysterm::Screen.new(input: IO::Memory.new, output: IO::Memory.new,
    error: IO::Memory.new, width: 80, height: 24)
end

# CSS length units → terminal cells via the settable `Geometry.unit_divisors`
# table: `cells = round(value / divisor)`.
describe "CSS geometry units" do
  it "converts a unit'd length to cells through the divisor table" do
    s = render_screen
    s.stylesheet = "Box#a { width: 200px; left: 12px; }"
    a = Widget::Box.new parent: s, content: "x"
    a.css_id = "a"
    s._render
    a.width.should eq 20 # 200 / 10
    a.left.should eq 1   # round(12 / 10)
  end

  it "passes percentage / keyword forms straight through" do
    s = render_screen
    s.stylesheet = "Box#a { top: 50%; }"
    a = Widget::Box.new parent: s, content: "x"
    a.css_id = "a"
    s._render
    a.top.should eq "50%"
  end

  it "ignores a unit mapped to nil (physical units), leaving geometry untouched" do
    s = render_screen
    s.stylesheet = "Box#a { width: 7; height: 3cm; }"
    a = Widget::Box.new parent: s, content: "x"
    a.css_id = "a"
    s._render
    a.width.should eq 7    # the mapped unit's sibling still applies
    a.height.should be_nil # 3cm dropped -> never set
  end

  it "scales units in non-geometry lengths (padding/margin) too" do
    s = render_screen
    s.stylesheet = "Box#a { padding: 200px; margin-left: 1em; }"
    a = Widget::Box.new parent: s, content: "x"
    a.css_id = "a"
    s._render
    a.style.padding.left.should eq 20 # 200 / 10            (horizontal)
    a.style.padding.top.should eq 10  # 200 / (10 * 2:1 aspect) (vertical)
    a.style.margin.left.should eq 1   # 1 / 1
  end

  it "caps a stretched/percentage width at max-width" do
    s = render_screen
    s.stylesheet = "Box#a { width: 100%; max-width: 10; }"
    a = Widget::Box.new parent: s, content: "x"
    a.css_id = "a"
    s._render
    a.max_width.should eq 10
    a.awidth.should eq 10 # 80% of the 80-wide screen, clamped to 10
  end

  it "raises a too-small width to min-width" do
    s = render_screen
    s.stylesheet = "Box#a { width: 4; min-width: 8; }"
    a = Widget::Box.new parent: s, content: "x"
    a.css_id = "a"
    s._render
    a.awidth.should eq 8
  end

  it "lets min-width win when it exceeds max-width (per CSS)" do
    s = render_screen
    s.stylesheet = "Box#a { width: 100%; max-width: 5; min-width: 10; }"
    a = Widget::Box.new parent: s, content: "x"
    a.css_id = "a"
    s._render
    a.awidth.should eq 10
  end

  it "scales unit'd size constraints through the divisor table (and ignores %)" do
    s = render_screen
    s.stylesheet = "Box#a { height: 100%; max-height: 200px; min-height: 50%; }"
    a = Widget::Box.new parent: s, content: "x"
    a.css_id = "a"
    s._render
    a.max_height.should eq 10  # 200 / (10 * 2:1 aspect) -- vertical
    a.min_height.should be_nil # `50%` has no cell mapping -> ignored
    a.aheight.should eq 10     # full 24-row height clamped to 10
  end

  it "resolves a viewport unit against the screen size, reactively on resize" do
    s = render_screen # 80 x 24
    s.stylesheet = "Box#a { width: 50vw; height: 100vh; top: 25vmin; }"
    a = Widget::Box.new parent: s, content: "x"
    a.css_id = "a"
    s._render
    # The viewport string is kept on the widget (not baked to cells), so it can
    # re-resolve against the screen every frame.
    a.width.should eq "50vw"
    a.awidth.should eq 40  # 50% of 80
    a.aheight.should eq 24 # 100% of 24
    a.atop.should eq 6     # 25% of min(80, 24)

    # Resize the terminal: the same widget re-resolves against the new size.
    s.width = 120
    s.height = 40
    s._render
    a.awidth.should eq 60  # 50% of 120
    a.aheight.should eq 40 # 100% of 40
    a.atop.should eq 10    # 25% of min(120, 40)
  end

  it "evaluates calc() to cells when every term resolves" do
    s = render_screen
    s.stylesheet = "Box#a { width: calc(200px + 2em); left: calc(8px - 2px); }"
    a = Widget::Box.new parent: s, content: "x"
    a.css_id = "a"
    s._render
    a.width.should eq 22 # 20 + 2
    a.left.should eq 1   # round(0.8 - 0.2)
  end

  it "ignores a calc() that needs layout context (a percentage term)" do
    s = render_screen
    s.stylesheet = "Box#a { width: 7; height: calc(50% - 10px); }"
    a = Widget::Box.new parent: s, content: "x"
    a.css_id = "a"
    s._render
    a.width.should eq 7    # sibling still applies
    a.height.should be_nil # calc with `%` -> dropped, never set
  end

  it "clamps a sub-cell border width up to 1 so it stays visible" do
    s = render_screen
    s.stylesheet = "Box#a { border-width: 2px; border-left-width: 0; }"
    a = Widget::Box.new parent: s, content: "x"
    a.css_id = "a"
    s._render
    a.style.border.top.should eq 1  # 2px rounds to 0 -> clamped to 1
    a.style.border.left.should eq 0 # explicit 0 stays 0
  end

  it "clamps an absurd length instead of overflowing (never raises)" do
    s = render_screen
    s.stylesheet = "Box#a { width: 99999999999px; height: calc(99999999999px * 99); }"
    a = Widget::Box.new parent: s, content: "x"
    a.css_id = "a"
    s._render # must not raise OverflowError
    a.width.should eq Int32::MAX
    a.height.should eq Int32::MAX
  end

  it "seeds the px divisor from the css.px_per_cell config option" do
    Superconf.css_px_per_cell = 5.0
    begin
      s = render_screen
      s.stylesheet = "Box#a { width: 200px; }"
      a = Widget::Box.new parent: s, content: "x"
      a.css_id = "a"
      s._render
      a.width.should eq 40 # 200 / 5
    ensure
      Superconf.css_px_per_cell = 10.0 # back to default ⇒ un-configured
      Crysterm::CSS::Length.divisors["px"] = 10.0
    end
  end

  it "seeds divisors from a css.unit_divisors map, with px_per_cell winning for px" do
    Superconf.css_unit_divisors = "px=4,em=2,cm=none,junk"
    Superconf.css_px_per_cell = 8.0
    begin
      s = render_screen
      s.stylesheet = "Box#a { width: 200px; height: 4em; }"
      a = Widget::Box.new parent: s, content: "x"
      a.css_id = "a"
      s._render
      a.width.should eq 25 # map px=4, then px_per_cell=8 wins ⇒ 200 / 8
      a.height.should eq 2 # em=2 from the map ⇒ 4 / 2
    ensure
      Superconf.css_unit_divisors = ""
      Superconf.css_px_per_cell = 10.0
      Crysterm::CSS::Length.divisors["px"] = 10.0
      Crysterm::CSS::Length.divisors["em"] = 1.0
    end
  end

  it "maps the same absolute length to fewer cells vertically (cell aspect ratio)" do
    s = render_screen
    # width and height carry the *same* px length; the vertical one resolves to
    # fewer cells because a cell is taller than wide (default 2:1).
    s.stylesheet = "Box#a { width: 200px; height: 200px; }"
    a = Widget::Box.new parent: s, content: "x"
    a.css_id = "a"
    s._render
    a.width.should eq 20  # 200 / 10
    a.height.should eq 10 # 200 / (10 * 2.0)
  end

  it "leaves relative units (em/ch) isotropic regardless of axis" do
    s = render_screen
    s.stylesheet = "Box#a { width: 4em; height: 4em; }"
    a = Widget::Box.new parent: s, content: "x"
    a.css_id = "a"
    s._render
    a.width.should eq 4  # 4 / 1
    a.height.should eq 4 # 4 / 1 -- not scaled by the aspect ratio
  end

  it "honors an explicit css.cell_aspect_ratio override" do
    Superconf.css_cell_aspect_ratio = 4.0
    begin
      s = render_screen
      s.stylesheet = "Box#a { width: 200px; height: 200px; }"
      a = Widget::Box.new parent: s, content: "x"
      a.css_id = "a"
      s._render
      a.width.should eq 20 # 200 / 10 (horizontal, unaffected)
      a.height.should eq 5 # 200 / (10 * 4.0)
    ensure
      Superconf.css_cell_aspect_ratio = 2.0
      Crysterm::CSS::Length.cell_aspect_ratio = 2.0
    end
  end

  it "honors a retuned divisor" do
    original = Crysterm::CSS::Geometry.unit_divisors["px"]
    begin
      Crysterm::CSS::Geometry.unit_divisors["px"] = 20.0
      s = render_screen
      s.stylesheet = "Box#a { width: 200px; }"
      a = Widget::Box.new parent: s, content: "x"
      a.css_id = "a"
      s._render
      a.width.should eq 10 # 200 / 20
    ensure
      Crysterm::CSS::Geometry.unit_divisors["px"] = original
    end
  end
end
