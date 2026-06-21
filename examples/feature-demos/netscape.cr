# FEATURED ANIMATION: the classic Netscape throbber, shown two ways at once —
#
#   left  — the animation at a FIXED size
#   right — the SAME animation while its box is RESIZED every frame
#
# It demonstrates that every image backend now ANIMATES *and* resizes: each
# shown frame is sampled to the current box (lazily, cached per size).
#
# The BACKEND env var picks the renderer; all of these animate:
#   glyph (default) — sub-cell Unicode glyphs (octant: 2x4 sub-pixels per cell),
#                     ~8x the resolution of plain cells and capturable anywhere
#   kitty | sixel | iterm — true-pixel terminal graphics (needs a capable
#                     terminal: kitty/WezTerm/Konsole, an xterm -ti vt340, …)
#   ansi            — one cell per pixel (lowest resolution)
#
# Load a different image with IMAGE=… .

require "../../src/crysterm"

include Crysterm

img_path = ENV["IMAGE"]? || "#{__DIR__}/../../screenshots/netscape.gif"
name = File.basename(img_path)

# Pick the rendering backend; all of these animate and resize.
def make_image(backend, **opts)
  case backend
  when "kitty" then Widget::Image::Kitty.new(**opts)
  when "sixel" then Widget::Image::Sixel.new(**opts)
  when "iterm" then Widget::Image::Iterm.new(**opts)
  when "ansi"  then Widget::Image::Ansi.new(**opts)
  else              Widget::Image::Glyph.new(**opts, mode: Widget::Image::Glyph::Mode::Octant)
  end
end

backend = ENV["BACKEND"]? || "glyph"

s = Screen.new title: "Netscape"
s.show_fps = nil

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}#{name}  ·  #{backend} graphics  ·  left: fixed size   ·   right: resizing while it plays{/center}",
  parse_tags: true, style: Style.new(fg: "white", bg: "#202830")

ih = s.aheight - 1
half = s.awidth // 2

# Left: the animation at a fixed size.
make_image backend,
  parent: s, top: 1, left: 0, width: half, height: ih,
  fit: Widget::Image::Fit::Contain, file: img_path,
  style: Style.new(border: true)

# Right: the same animation in a box we resize on every frame.
right = make_image backend,
  parent: s, top: 1, left: half, width: s.awidth - half, height: ih,
  fit: Widget::Image::Fit::Contain, file: img_path,
  style: Style.new(border: true)

rmaxw = s.awidth - half
t = 0.0
s.every(0.1.seconds) do
  phase = t % 2.0
  f = phase < 1.0 ? phase : 2.0 - phase
  right.width = (12 + (rmaxw - 12) * f).to_i
  right.height = (5 + (ih - 5) * f).to_i
  t += 0.12
end

s.render
s.exec
