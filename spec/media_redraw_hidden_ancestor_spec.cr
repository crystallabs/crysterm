require "./spec_helper"

include Crysterm

# Regression: `Media::Graphics#redraw_image` (a standalone `Rendered` screen
# listener) guarded with `return unless visible?`, which only checks the
# widget's own visibility. When an ancestor was hidden, the widget stayed
# own-visible but had no rendered position, so `coords(true) ->
# last_rendered_position` raised "Shouldn't happen" instead of returning nil,
# crashing the render-loop fiber. Fix walks the parent chain and skips the
# overlay paint if any ancestor is hidden, mirroring `Capture`'s tree-aware
# visibility check.
describe "Media::Graphics overlay redraw with a hidden ancestor" do
  it "does not raise when a render happens after an ancestor is hidden" do
    s = Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new,
      error: IO::Memory.new, width: 20, height: 10)
    parent = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 6
    img = Widget::Media::Sixel.new parent: parent, top: 0, left: 0, width: 6, height: 4
    red = PNGGIF::Pixel.new(255, 0, 0, 255)
    img.bitmap = Array(Array(PNGGIF::Pixel)).new(8) { Array(PNGGIF::Pixel).new(8, red) }

    s.repaint # first render establishes positions

    # The widget itself is still own-visible; only its container is hidden.
    parent.hide
    img.visible?.should be_true

    # Before the fix this raised inside redraw_image (Rendered listener).
    s.repaint
  end
end
