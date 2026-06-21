# FEATURE: single-threaded, fiber-based, lock-free rendering (Qt-style).
#
# Every widget below is animated by its OWN independent fiber, each calling
# `screen.render` whenever it likes. Crysterm coordinates them through a single
# capacity-1 "doorbell" channel: bursts of render requests coalesce into frames
# rendered on one fiber, so widget state is never mutated concurrently and no
# locks are needed. The result is many things moving at once, smoothly.

require "../../src/crysterm"

include Crysterm

s = Screen.new title: "Concurrent rendering"
s.show_fps = nil

Widget::Box.new \
  parent: s,
  top: 0, left: 0, width: "100%", height: 3,
  content: "{center}Lock-free fiber rendering{/center}\n" \
           "{center}Each widget animates from its own fiber; renders coalesce into frames.{/center}",
  parse_tags: true,
  style: Style.new(fg: "white", bg: "#202840", border: true)

# Five progress bars, each advancing at its own pace from its own fiber.
colors = [0xe05050, 0x50e050, 0x5080e0, 0xe0c050, 0xc050e0]
5.times do |i|
  pb = Widget::ProgressBar.new \
    parent: s,
    top: 4 + i, left: 2, width: 46, height: 1,
    filled: 0,
    style: Style.new(fg: colors[i], bg: 0x303030)
  step = i + 1
  s.every((0.05 + i * 0.02).seconds) do
    pb.filled += step
    pb.filled = 0 if pb.filled > 100
  end
end

# Two spinners, independent fibers.
spin1 = Widget::Loading.new \
  parent: s, top: 4, left: 52, width: 24, height: 3,
  content: "Worker A", style: Style.new(fg: "cyan", border: true)
spin2 = Widget::Loading.new \
  parent: s, top: 8, left: 52, width: 24, height: 3,
  content: "Worker B", style: Style.new(fg: "magenta", border: true)
spin1.start
spin2.start

# A marker bouncing horizontally, its own fiber.
marker = Widget::Box.new \
  parent: s, top: 11, left: 2, width: 6, height: 1,
  content: "{center}o{/center}", parse_tags: true,
  style: Style.new(fg: "black", bg: "yellow")
pos = 0.0
s.every(0.04.seconds) do
  marker.clear_last_rendered_position
  marker.left = (2 + (Math.sin(pos) * 0.5 + 0.5) * (s.awidth - 8)).to_i
  pos += 0.15
end

s.exec
