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
