require "./spec_helper"

include Crysterm

private def mem_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 20,
    height: 8,
    default_quit_keys: false)
end

# Blends nothing: a `fill: false` widget draws no background, so its interior
# must show whatever is behind it. Returns the resulting background color of a
# cell inside the widget's content region, over a solid red backdrop.
private def fill_false_interior_bg(padding : Int32)
  s = mem_screen
  Crysterm::Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 8,
    style: Crysterm::Style.new(bg: "red")

  st = Crysterm::Style.new
  st.fill = false
  st.padding = Crysterm::Padding.new(padding, padding, padding, padding) if padding > 0

  b = Crysterm::Widget::Box.new parent: s, top: 1, left: 1, width: 10, height: 5,
    style: st, content: ""
  s._render

  lp = b.lpos.not_nil!
  y = lp.yi + padding + 1
  x = lp.xi + padding + 1
  Crysterm::Attr.bg(s.lines[y][x].attr)
end

# Regression: a `fill: false` widget is transparent (its content loop draws no
# cell). The render's pre-fill pass runs only when the widget has padding or
# non-top vertical alignment; routing a `fill: false` widget through that pass'
# whole-box fill made it *opaque* — but only when it happened to have padding.
# So padding silently toggled the widget's transparency.
describe "Widget with fill: false and padding" do
  it "stays transparent regardless of padding" do
    unpadded = fill_false_interior_bg(0)
    padded = fill_false_interior_bg(2)

    # Both must show the red backdrop behind the transparent widget. Before the
    # fix, `padded` was the terminal default (the whole box was filled), so
    # `padded != unpadded`.
    padded.should eq unpadded
  end
end
