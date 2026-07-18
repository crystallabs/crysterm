# FEATURE: 24-bit TrueColor + alpha-compositing.
#
# Crysterm stores colors as full 24-bit RGB, reducing to the terminal's real
# capability only at output time. It can also blend colors in RGB space,
# which is how translucent ("alpha") widgets and soft shadows are drawn.
#
# This demo fills the screen with a smooth 24-bit color sweep and slides two
# translucent boxes with shadows across it, mixing colors per channel where
# they overlap.

require "../../src/crysterm"

include Crysterm

s = Window.new title: "TrueColor"

w = s.awidth
h = s.aheight

# Static `Gradient` (no `animate:`, renders once), one color per column. The
# explicit `stops:` give a soft cyan→green→amber→red sweep interpolated
# in RGB, instead of the default's full-saturation HSV rainbow.
Widget::Gradient.new parent: s, top: 0, left: 0, width: "100%", height: "100%",
  stops: [0x00dbdf, 0x61fc9f, 0xb4f647, 0xebcb00, 0xff8100, 0xeb2300, 0xb40000, 0x610000, 0x000000]

# Caption strip drawn on top of the gradient.
Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}24-bit TrueColor & alpha compositing{/center}", parse_tags: true,
  style: Style.new(fg: "white", bg: "#202830")

box1 = Widget::Box.new \
  parent: s,
  top: 2, left: 2, width: 30, height: 8,
  content: "{center}24-bit TrueColor{/center}\n\n" \
           "{center}Translucent box with a\nshadow, blended in RGB.{/center}",
  parse_tags: true,
  style: Style.new(bg: 0x103080, alpha: true, border: true, shadow: true)

box2 = Widget::Box.new \
  parent: s,
  top: 5, left: 40, width: 30, height: 8,
  content: "{center}Alpha compositing{/center}\n\n" \
           "{center}Slides over the one\non the left.{/center}",
  parse_tags: true,
  style: Style.new(bg: 0x208020, alpha: true, border: true, shadow: true)

t = 0.0
s.every(0.06.seconds) do
  box1.clear_last_rendered_position
  box2.clear_last_rendered_position
  box1.left = (2 + (Math.sin(t) * 0.5 + 0.5) * (w - 32)).to_i
  box2.left = (2 + (Math.sin(t + Math::PI) * 0.5 + 0.5) * (w - 32)).to_i
  t += 0.12
end

s.exec
