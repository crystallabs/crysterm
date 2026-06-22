# IMPRESSIVE DEMO: a TRUE-color image overlay via w3mimgdisplay.
#
# Unlike Image::Ansi / Image::Glyph (which decode the image and draw it into the
# terminal's character cells), `Widget::Image::Overlay` shells out to the external
# `w3mimgdisplay` helper, which paints the *actual pixels* of the image directly
# onto the terminal window — full photographic quality, on top of the cells.
#
# This needs a w3m-image-capable terminal (e.g. xterm) on a real display; it
# does NOT work over a plain pipe/pseudo-terminal, since the overlay is real
# graphics rather than characters in the output stream.

require "../../src/crysterm"

include Crysterm

s = Screen.new title: "Overlay"

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Image::Overlay  ·  w3mimgdisplay true-color overlay  ·  the Matterhorn{/center}",
  parse_tags: true, style: Style.new(fg: "white", bg: "#202830")

Widget::Image::Overlay.new \
  parent: s, top: 1, left: 0, width: "100%", height: "100%-1",
  stretch: true,
  file: "#{__DIR__}/../../screenshots/matterhorn.png"

# Optional self-terminate (used by the screenshot tooling so nothing external
# has to be killed): OVERLAY_SECONDS=8 makes the demo exit on its own.
if secs = ENV["OVERLAY_SECONDS"]?
  spawn do
    sleep secs.to_f.seconds
    s.destroy
    exit
  end
end

s.exec
