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
    a.style.padding.top.should eq 20 # 200 / 10
    a.style.margin.left.should eq 1  # 1 / 1
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
    a.max_height.should eq 20  # 200 / 10
    a.min_height.should be_nil # `50%` has no cell mapping -> ignored
    a.aheight.should eq 20     # full 24-row height clamped to 20
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
