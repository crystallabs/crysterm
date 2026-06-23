# DEMO: live resizing. The image box oscillates in size every frame and the
# backend RE-SAMPLES the source to fit it — the whole point of the resize
# refactor: keep a resolution-independent source and derive the sized render for
# whatever box is current (here with `fit: Contain`, so aspect is preserved and
# the remainder is letterboxed). Uses `Media::Glyph` so the normal `ttygif.py`
# recorder can capture it as a GIF.

require "../../src/crysterm"

include Crysterm

s = Screen.new title: "Resize"

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Live resize — the source re-samples to the box (fit: Contain){/center}",
  parse_tags: true, style: Style.new(fg: "white", bg: "#202830")

img = Widget::Media::Glyph.new \
  parent: s, top: 2, left: 2, width: 20, height: 6,
  mode: Widget::Media::Glyph::Mode::Octant,
  fit: Widget::Media::Fit::Contain, animate: false,
  file: "#{__DIR__}/../../screenshots/matterhorn.png",
  style: Style.new(border: true)

# Oscillate the box size; each render re-samples the image to the new box.
maxw = s.awidth - 4
maxh = s.aheight - 4
t = 0.0
s.every(0.05.seconds) do
  # Smooth triangle wave 0..1.
  phase = (t % 2.0)
  f = phase < 1.0 ? phase : 2.0 - phase
  img.width = (12 + (maxw - 12) * f).to_i
  img.height = (4 + (maxh - 4) * f).to_i
  t += 0.08
end

s.render
s.exec
