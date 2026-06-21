# IMPRESSIVE DEMO: a true-color image overlay via Überzug / Überzug++.
#
# `Widget::Image::Ueberzug` is the modern successor to the w3mimgdisplay overlay:
# it drives the external `ueberzug`/`ueberzugpp` helper (JSON on stdin), which
# paints the actual image pixels in an X11 child window placed over the terminal
# — full photographic quality, positioned in terminal cells. Here: the
# Matterhorn.
#
# Needs the `ueberzug` (or `ueberzugpp`) binary on PATH and a real X display.

require "../../src/crysterm"

include Crysterm

s = Screen.new title: "Ueberzug"
s.show_fps = nil

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Image::Ueberzug  ·  überzug X11 overlay (w3m successor)  ·  the Matterhorn{/center}",
  parse_tags: true, style: Style.new(fg: "white", bg: "#202830")

unless Widget::Image::Ueberzug.binary
  Widget::Box.new \
    parent: s, top: 3, left: 2, width: "100%-4", height: 3,
    content: "{center}ueberzug / ueberzugpp not found on PATH — overlay unavailable here.{/center}",
    parse_tags: true, style: Style.new(fg: "yellow")
end

Widget::Image::Ueberzug.new \
  parent: s, top: 1, left: 0, width: s.awidth, height: s.aheight - 1,
  scaler: "forced_cover",
  file: "#{__DIR__}/../../screenshots/matterhorn.png"

s.on(Event::KeyPress) do |e|
  if e.char == 'q' || e.key == Tput::Key::CtrlQ
    s.destroy
    exit
  end
end

if secs = ENV["DEMO_SECONDS"]?
  spawn do
    sleep secs.to_f.seconds
    s.destroy
    exit
  end
end

s.render
s.exec
