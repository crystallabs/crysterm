require "../src/crysterm"

# Port of Blessed's test/widget-ansiimage.js
#
# Demonstrates `Widget::ANSIImage`, which decodes a PNG/APNG/GIF itself (using
# the pure-Crystal `Crysterm::PNG` reader) and draws it into the normal cell
# grid — one terminal cell per downscaled pixel, colored via TrueColor. Unlike
# `Widget::OverlayImage` it needs no external `w3mimgdisplay` helper, so it works
# on any TrueColor terminal.
#
# Pass an image path as the first argument, or it defaults to a bundled
# screenshot. Press `q` to quit. Animated images (APNG / animated GIF) play
# automatically.
module Crysterm
  include Tput::Namespace

  s = Screen.new always_propagate: [::Tput::Key::CtrlQ]

  file = ARGV[0]? || begin
    up = File.expand_path(File.join(__DIR__, "..", "screenshots", "netscape.gif"))
    here = File.expand_path(File.join("screenshots", "netscape.gif"))
    File.exists?(up) ? up : here
  end

  Widget::Box.new \
    parent: s,
    top: 0,
    left: 0,
    height: 1,
    width: "100%",
    content: "Widget::ANSIImage — press q to quit"

  img = Widget::ANSIImage.new(
    file: file,
    parent: s,
    top: 2,
    left: "center",
    width: 50,
    style: Style.new(border: BorderType::Line),
  )

  img.focus

  s.on(Event::KeyPress) do |e|
    if e.char == 'q' || e.key == ::Tput::Key::CtrlQ
      s.destroy
      exit
    end
  end

  s.exec
end
