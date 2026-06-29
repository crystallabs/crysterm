require "./spec_helper"

include Crysterm

# Regression: `Capture` composites in-band terminal-graphics widgets (sixel /
# kitty / iterm / regis) by walking the widget tree directly
# (`collect_graphics`), separately from the text-cell pass. That walk only
# consulted a graphics widget's OWN `visible?` flag (via `capture_layer`), not
# its ancestors' — so a graphics widget sitting inside a HIDDEN container was
# still painted into the capture even though the live terminal never shows it
# (a hidden widget's `_render`, and thus its escape sequence, is skipped).
#
# A faithful capture must mirror what the terminal displays, so a hidden
# subtree's graphics must be excluded. Driven headlessly over in-memory IOs.

private def graphics_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new,
    error: IO::Memory.new, width: 20, height: 10)
end

# A small solid-red RGBA bitmap — a color that never occurs among the capture
# defaults (black bg, silver fg), so its presence is unambiguous.
private def red_bitmap(w = 8, h = 8)
  red = PNGGIF::Pixel.new(255, 0, 0, 255)
  Array(Array(PNGGIF::Pixel)).new(h) { Array(PNGGIF::Pixel).new(w, red) }
end

private def capture_has_red?(bmp)
  bmp.any? do |row|
    row.any? { |px| px.r == 255 && px.g == 0 && px.b == 0 }
  end
end

describe "Capture of in-band graphics inside a hidden subtree" do
  it "excludes a graphics widget whose container is hidden" do
    s = graphics_screen
    parent = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 6
    img = Widget::Media::Sixel.new parent: parent, top: 0, left: 0, width: 6, height: 4
    img.bitmap = red_bitmap

    # Visible: the image's pixels are composited into the capture.
    s._render
    capture_has_red?(Crysterm::Capture.render(s, 0, s.awidth, 0, s.aheight)).should be_true

    # Hiding the *parent* (the image itself stays flag-visible) must remove the
    # image from the capture, since the terminal would no longer show it.
    # `Capture.render` recomputes each graphics layer's geometry itself, so this
    # needs no re-render (and avoids the unrelated Media-overlay redraw path that
    # a hidden widget's `_render` walks).
    parent.hide
    capture_has_red?(Crysterm::Capture.render(s, 0, s.awidth, 0, s.aheight)).should be_false
  end
end
