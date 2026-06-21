# IMPRESSIVE DEMO: a true-color image via the iTerm2 inline-images protocol.
#
# `Widget::Image::Iterm` base64-encodes the *original* PNG file and sends it in
# an `OSC 1337;File=…` escape that a supporting terminal (iTerm2, WezTerm,
# Konsole, mintty, VS Code's terminal, …) decodes and draws — full true-color,
# no decode or palette on our side. Here: the Matterhorn, sized to the cell box.
#
# Needs an iTerm2-inline-images-capable terminal on a real display.

require "../../src/crysterm"

include Crysterm

s = Screen.new title: "Iterm"
s.show_fps = nil

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Image::Iterm  ·  iTerm2 inline-images protocol (OSC 1337)  ·  the Matterhorn{/center}",
  parse_tags: true, style: Style.new(fg: "white", bg: "#202830")

iw = s.awidth
ih = s.aheight - 1

Widget::Image::Iterm.new \
  parent: s, top: 1, left: 0, width: iw, height: ih,
  file: "#{__DIR__}/../../screenshots/matterhorn.png"

if secs = ENV["DEMO_SECONDS"]?
  spawn do
    sleep secs.to_f.seconds
    s.destroy
    exit
  end
end

s.render
s.exec
