# FEATURE: decorators & styling — borders, shadows, and text attributes.
#
# Styles carry fg/bg colors, border type (line or solid bg), drop shadows
# (alpha-blended), and text attributes (bold, underline, inverse), all set per
# widget via `Style.new(...)` or inline `{tags}` in content.

require "../../src/crysterm"

include Crysterm

s = Screen.new title: "Styling"
s.show_fps = nil

# A neutral backdrop behind everything, so the drop shadows (which darken
# whatever is *behind* a widget) are actually visible instead of black-on-black.
Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: "100%",
  style: Style.new(bg: "#3a4250")

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Borders, shadows and text attributes{/center}", parse_tags: true,
  style: Style.new(fg: "white", bg: "#403040")

# Line border + shadow
Widget::Box.new \
  parent: s, top: 2, left: 2, width: 22, height: 5,
  content: "{center}Line border\n+ drop shadow{/center}", parse_tags: true,
  style: Style.new(fg: "white", bg: "#2050a0", border: Border.new(type: :line), shadow: true)

# Solid (bg) border, with a shadow on all four sides. Left/right are 2 cells and
# top/bottom 1, so it looks even (terminal cells are about twice as tall as wide).
Widget::Box.new \
  parent: s, top: 2, left: 28, width: 22, height: 5,
  content: "{center}Solid bg border\n+ even shadow{/center}", parse_tags: true,
  style: Style.new(fg: "black", bg: "#d0a020", border: Border.new(type: :bg, bg: "#a07010"),
    shadow: Shadow.new(2, 1, 2, 1))

# Text attributes via inline tags
Widget::Box.new \
  parent: s, top: 2, left: 54, width: 24, height: 5,
  content: "{bold}bold{/bold} {underline}underline{/underline} {italic}italic{/italic}\n" \
           "{inverse}inverse{/inverse}\n" \
           "{red-fg}red{/} {green-fg}green{/} {blue-fg}blue{/}",
  parse_tags: true,
  style: Style.new(fg: "white", bg: "#101010", border: true)

# A row of animated color swatches (each a small Box with a 24-bit bg).
frame = Widget::Box.new \
  parent: s, top: 8, left: 2, width: 76, height: 5,
  content: "Animated 24-bit swatches:", parse_tags: true,
  style: Style.new(fg: "white", bg: "#101010", border: true)

n = 70
swatches = [] of Widget::Box
n.times do |i|
  swatches << Widget::Box.new(
    parent: frame, top: 1, left: 1 + i, width: 1, height: 2,
    style: Style.new(bg: "#000000"))
end

hsv = ->(h : Int32) {
  x = (255 * (1 - ((h / 60.0) % 2 - 1).abs)).to_i.clamp(0, 255)
  r, g, b = case (h // 60) % 6
            when 0 then {255, x, 0}
            when 1 then {x, 255, 0}
            when 2 then {0, 255, x}
            when 3 then {0, x, 255}
            when 4 then {x, 0, 255}
            else        {255, 0, x}
            end
  "#%02x%02x%02x" % {r, g, b}
}

s.on(Event::KeyPress) do |e|
  if e.char == 'q' || e.key == Tput::Key::CtrlQ
    s.destroy
    exit
  end
end

phase = 0
spawn do
  loop do
    swatches.each_with_index do |sw, i|
      sw.style.bg = hsv.call((i * 5 + phase) % 360)
    end
    phase = (phase + 12) % 360
    s.render
    sleep 0.1.seconds
  end
end

s.exec
