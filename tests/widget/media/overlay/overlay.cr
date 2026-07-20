# True-color image overlay via w3mimgdisplay.
#
# Unlike Media::Ansi / Media::Glyph (which decode the image into terminal
# character cells), `Widget::Media::Overlay` shells out to the external
# `w3mimgdisplay` helper, which paints the actual pixels directly onto the
# terminal window, on top of the cells.
#
# Needs a w3m-image-capable terminal (e.g. xterm) on a real display; does not
# work over a plain pipe/pseudo-terminal since the overlay is real graphics,
# not characters in the output stream.

require "../../../../src/crysterm"

include Crysterm

s = Window.new title: "Overlay"

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Media::Overlay  ·  w3mimgdisplay true-color overlay  ·  the Matterhorn{/center}",
  parse_tags: true, style: Style.new(fg: "white", bg: "#202830")

Widget::Media::Overlay.new \
  parent: s, top: 1, left: 0, width: "100%", height: "100%-1",
  fit: :stretch,
  file: "#{__DIR__}/../../../../data/image/matterhorn.png"

# Optional self-terminate for screenshot tooling: OVERLAY_SECONDS=8 makes the
# demo exit on its own.
if secs = ENV["OVERLAY_SECONDS"]?
  spawn do
    sleep secs.to_f.seconds
    s.destroy
    exit
  end
end

s.exec
