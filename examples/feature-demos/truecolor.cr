# FEATURE: 24-bit TrueColor + alpha-compositing.
#
# Crysterm stores colors as full 24-bit RGB and only reduces them to the
# terminal's real capability at output time. It can also *blend* colors in RGB
# space, which is how translucent ("alpha") widgets and soft shadows are drawn.
#
# This demo fills the screen with a smooth 24-bit color sweep (one full-height
# strip per column) and slides two translucent boxes with shadows across it.
# Where a box overlaps the sweep and the other box, the colors mix per channel.

require "../../src/crysterm"

include Crysterm

s = Screen.new title: "TrueColor"
s.show_fps = nil

w = s.awidth
h = s.aheight

# Background: a smooth 24-bit rainbow sweep — a single static `Gradient` that
# paints one color per column (no `animate:`, so it just renders once).
Widget::Gradient.new parent: s, top: 0, left: 0, width: "100%", height: "100%"

box1 = Widget::Box.new \
  parent: s,
  top: 2, left: 2, width: 30, height: 8,
  content: "{center}24-bit TrueColor{/center}\n\n" \
           "{center}Translucent box with a\nshadow, blended in RGB.{/center}",
  parse_tags: true,
  style: Style.new(bg: "#103080", alpha: true, border: true, shadow: true)

box2 = Widget::Box.new \
  parent: s,
  top: 5, left: 40, width: 30, height: 8,
  content: "{center}Alpha compositing{/center}\n\n" \
           "{center}Slides over the one\non the left.{/center}",
  parse_tags: true,
  style: Style.new(bg: "#208020", alpha: true, border: true, shadow: true)

t = 0.0
s.every(0.06.seconds) do
  box1.clear_last_rendered_position
  box2.clear_last_rendered_position
  box1.left = (2 + (Math.sin(t) * 0.5 + 0.5) * (w - 32)).to_i
  box2.left = (2 + (Math.sin(t + Math::PI) * 0.5 + 0.5) * (w - 32)).to_i
  t += 0.12
end

s.exec
