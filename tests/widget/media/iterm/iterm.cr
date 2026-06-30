# IMPRESSIVE DEMO: a true-color image via the iTerm2 inline-images protocol.
#
# `Widget::Media::Iterm` base64-encodes the *original* PNG file and sends it in
# an `OSC 1337;File=…` escape that a supporting terminal (iTerm2, WezTerm,
# Konsole, mintty, VS Code's terminal, …) decodes and draws — full true-color,
# no decode or palette on our side. Here: the Matterhorn, sized to the cell box.
#
# Needs an iTerm2-inline-images-capable terminal on a real display.

require "../../../../src/crysterm"

include Crysterm

s = Window.new title: "Iterm"

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Media::Iterm  ·  iTerm2 inline-images protocol (OSC 1337)  ·  the Matterhorn{/center}",
  parse_tags: true, style: Style.new(fg: "white", bg: "#202830")

# Leave the title row at the top AND one row free at the bottom: the terminal
# advances the cursor below an inline image, so one reaching the last screen row
# would scroll the title off the top. One spare row keeps the cursor on-screen.
iw = s.awidth
ih = s.aheight - 2

Widget::Media::Iterm.new \
  parent: s, top: 1, left: 0, width: iw, height: ih,
  file: "#{__DIR__}/../../../../data/image/matterhorn.png"

if secs = ENV["DEMO_SECONDS"]?
  spawn do
    sleep secs.to_f.seconds
    s.destroy
    exit
  end
end

s.render
s.exec
