# DEMO: the Widget::Fps debug overlay.
#
# `Widget::Fps` displays live rendering-performance figures for the screen:
#   R    frames/sec the render (compositing) phase could sustain
#   D    frames/sec the draw (terminal output) phase could sustain
#   FPS  frames/sec the whole frame could sustain
#   TX   bytes/sec written to the terminal (with rolling average)
#   Σ    cumulative bytes ever written to the terminal
#
# What it prints is driven by a printf-style `format` plus an `args` list naming
# which metrics fill the slots, so any element is "disabled" by leaving it out.
# Here we show the everything-on default at the bottom-left and a trimmed,
# custom overlay at the top-right.

require "../../src/crysterm"

include Crysterm

s = Screen.new title: "FPS overlay"

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Widget::Fps overlay — animation drives the render loop · q quits{/center}",
  parse_tags: true, style: Style.new(fg: "white", bg: "#202838")

# A moving block keeps the render loop busy so the figures stay lively.
ball = Widget::Box.new \
  parent: s, top: 6, left: 0, width: 6, height: 3,
  content: "", style: Style.new(bg: 0x40e0c0)

# Default overlay: everything, bottom-left.
Widget::Fps.new parent: s

# Custom overlay: just the effective FPS and throughput, top-right. Fixed-width
# fields (`%5s`/`%9s`) keep the line from jittering as the numbers change width.
Widget::Fps.new \
  parent: s, top: 0, right: 0,
  format: "FPS %5s  TX %9s/s", args: [:fps, :throughput_h],
  style: Style.new(fg: "black", bg: "#f0d060")

x = 0
dx = 1
s.every(0.03.seconds) do
  x += dx
  if x <= 0 || x >= s.width - 6
    dx = -dx
    x = x.clamp(0, s.width - 6)
  end
  ball.left = x
end

s.exec
