require "./spec_helper"

include Crysterm

# Regression: `Media::Graphics#redraw_image` runs as a standalone `Rendered`
# screen listener (the in-band-graphics overlay), separate from the cell-render
# pass. Its guard was `return unless visible?`, which only checks the widget's
# OWN visibility flag. When an ANCESTOR was hidden, the graphics widget stayed
# own-visible but went off-screen; the hidden ancestor has no rendered position,
# so resolving the widget's coords (`_get_coords(true)` -> `last_rendered_position`)
# raised "Shouldn't happen" instead of returning nil, crashing the render-loop
# fiber on the next render after the ancestor was hidden.
#
# The fix walks the parent chain and skips the overlay paint if any ancestor is
# hidden, mirroring the tree-aware visibility `Capture` uses. Headless / in-memory.
describe "Media::Graphics overlay redraw with a hidden ancestor" do
  it "does not raise when a render happens after an ancestor is hidden" do
    s = Crysterm::Screen.new(input: IO::Memory.new, output: IO::Memory.new,
      error: IO::Memory.new, width: 20, height: 10)
    parent = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 6
    img = Widget::Media::Sixel.new parent: parent, top: 0, left: 0, width: 6, height: 4
    red = PNGGIF::Pixel.new(255, 0, 0, 255)
    img.bitmap = Array(Array(PNGGIF::Pixel)).new(8) { Array(PNGGIF::Pixel).new(8, red) }

    s._render # first render establishes positions

    # The widget itself is still own-visible; only its container is hidden.
    parent.hide
    img.visible?.should be_true

    # Before the fix this raised inside redraw_image (Rendered listener).
    s._render
  end
end
