# FEATURE: single-threaded, fiber-based, lock-free rendering (Qt-style).
#
# Every widget below is animated by its own independent fiber, calling
# `screen.render` whenever it likes. Crysterm coalesces bursts of render
# requests via a capacity-1 "doorbell" channel into frames on one fiber, so
# widget state is never mutated concurrently and no locks are needed.

require "../../src/crysterm"

include Crysterm
include Crysterm::Widgets

s = Window.new title: "Concurrent rendering"

Widget::Box.new \
  parent: s,
  top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Lock-free fiber rendering — each widget animates from its own fiber{/center}",
  parse_tags: true,
  style: Style.new(fg: "white", bg: "#202840")

# Five progress bars, each advancing at its own pace from its own fiber.
colors = [0xe05050, 0x50e050, 0x5080e0, 0xe0c050, 0xc050e0]
5.times do |i|
  # The percent portion is the bar's `indicator` sub-style. Set it explicitly
  # (an inline sub-style outranks the theme) to give each bar its own color
  # instead of the theme's uniform accent.
  pb = ProgressBar.new \
    parent: s,
    top: 2 + i, left: 2, width: 46, height: 1,
    percent: 0,
    style: Style.new(fg: colors[i], bg: 0x303030,
      indicator: Style.new(fg: colors[i]))
  step = i + 1
  s.every((0.05 + i * 0.02).seconds) do
    # `percent` clamps at 100, so `+= step; = 0 if > 100` could never wrap.
    # Restart from empty once full.
    pb.percent = pb.percent >= 100 ? 0 : pb.percent + step
  end
end

# Two spinners, independent fibers.
spin1 = Loading.new \
  parent: s, top: 2, left: 52, width: 24, height: 3,
  content: "Worker A", style: Style.new(fg: "cyan", border: true)
spin2 = Loading.new \
  parent: s, top: 6, left: 52, width: 24, height: 3,
  content: "Worker B", style: Style.new(fg: "magenta", border: true)
spin1.start
spin2.start

# A marker bouncing horizontally, its own fiber.
marker = Widget::Box.new \
  parent: s, top: 9, left: 2, width: 6, height: 1,
  content: "{center}o{/center}", parse_tags: true,
  style: Style.new(fg: "black", bg: "yellow")
pos = 0.0
s.every(0.04.seconds) do
  marker.clear_last_rendered_position
  marker.left = (2 + (Math.sin(pos) * 0.5 + 0.5) * (s.awidth - 8)).to_i
  pos += 0.15
end

# Live FPS overlay (bottom-left): counts the frames the doorbell coalesces
# these fibers' render bursts into.
Fps.new parent: s

s.exec
