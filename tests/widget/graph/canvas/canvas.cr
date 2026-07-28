# Example: Crysterm::Widget::Graph::Canvas
#
# Minimal, self-contained example of a single Canvas: an `#on_paint` block
# draws in logical coordinates with a `Painter` (here a sine wave plus its
# axis), and the result is rasterized through the best supported Media
# backend (braille glyphs in the headless capture).
# Run it:     crystal run tests/widget/graph/canvas/canvas.cr
require "../../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run "Canvas" do |window|
  window.stylesheet = "Canvas { border: solid; }"
  cv = GraphCanvas.new parent: window, top: "center", left: "center",
    width: 44, height: 14
  cv.on_paint do |p|
    p.set_window 0, -1.2, 6.28, 2.4 # logical: x in 0..2π, y in -1.2..1.2
    p.pen = 0x565f89
    p.draw_line 0, 0, 6.28, 0 # x axis
    p.pen = 0x40E0D0
    pts = (0..120).map { |i| {i * 6.28 / 120, Math.sin(i * 6.28 / 120)} }
    p.draw_polyline pts
  end
end
