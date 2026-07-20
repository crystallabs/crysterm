require "./spec_helper"

include Crysterm

private def mem_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 40,
    height: 12,
    default_quit_keys: false)
end

# Blends blue (alpha 0.5) over a solid red backdrop and returns the resulting
# background color of a cell well inside the box's content region.
private def alpha_content_bg(padding : Int32)
  s = mem_screen
  Crysterm::Widget::Box.new parent: s, top: 0, left: 0, width: 40, height: 12,
    style: Crysterm::Style.new(bg: "red")

  st = Crysterm::Style.new(bg: "blue")
  st.opacity = 0.5
  st.padding = Crysterm::Padding.new(padding, padding, padding, padding) if padding > 0

  b = Crysterm::Widget::Box.new parent: s, top: 2, left: 2, width: 20, height: 6,
    style: st, content: ""
  s.repaint

  lp = b.lpos.not_nil!
  # A cell inside the content region (offset past any padding).
  y = lp.yi + padding + 1
  x = lp.xi + padding + 1
  Crysterm::Attr.bg(s.lines[y][x].attr)
end

# Regression: a translucent (`style.opacity`) widget renders its interior by
# alpha-blending each cell over whatever is behind it. The per-cell content loop
# already blends every cell of the (padding/scrollbar-inset) content region, so
# the pre-fill pass must NOT also blend those cells — doing so double-blends the
# interior, making a padded (or vertically-aligned) translucent widget's content
# area more opaque than its own padding, and different from an unpadded one.
describe "Widget translucency (style.opacity) with padding" do
  it "blends the interior exactly once regardless of padding" do
    unpadded = alpha_content_bg(0)
    padded = alpha_content_bg(2)

    # Both must be the single blend of blue over red at alpha 0.5. Before the
    # fix, the padded box's interior was blended twice (bluer / more opaque),
    # so `padded != unpadded`.
    padded.should eq unpadded
  end
end
