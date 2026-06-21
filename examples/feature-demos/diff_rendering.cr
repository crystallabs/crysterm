# FEATURE: cell-based diff drawing optimization.
#
# Crysterm separates *rendering* (computing the next screen in memory) from
# *drawing* (emitting escape sequences). On each frame it diffs the new screen
# against the last one and only writes the cells that actually changed.
#
# This demo keeps a large static background and animates just a small counter.
# The built-in "R/D/FPS" overlay (bottom-left) reports renders / draws / fps —
# the draw work stays tiny because almost nothing changes between frames.
#
# NOTE: unlike the other demos, this one intentionally LEAVES the FPS overlay on.

require "../../src/crysterm"

include Crysterm

s = Screen.new title: "Diff drawing"
# (FPS overlay deliberately left enabled.)

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 4,
  content: "{center}Diff-based drawing{/center}\n" \
           "{center}Big static background, tiny animated region.{/center}\n" \
           "{center}Only changed cells are redrawn (see R/D/FPS below).{/center}",
  parse_tags: true,
  style: Style.new(fg: "white", bg: "#202830", border: true)

# A large, static, decorated background area.
Widget::Box.new \
  parent: s, top: 4, left: 0, width: 60, height: 9,
  content: "This whole panel is rendered every frame but DRAWN once,\n" \
           "because its cells never change. The diff engine skips them.\n\n" \
           "Static content ............................................\n" \
           "Static content ............................................\n" \
           "Static content ............................................",
  style: Style.new(fg: 0x80c0a0, bg: 0x0c1014, border: true)

# The only thing that actually changes each frame.
ticker = Widget::Box.new \
  parent: s, top: 4, left: 61, width: 17, height: 9, align: :hcenter,
  content: "", parse_tags: true,
  style: Style.new(fg: "yellow", bg: "#201810", border: true)

spinner = ["|", "/", "-", "\\"]

n = 0
s.every(0.05.seconds) do
  ticker.content = "\n{center}frame{/center}\n{center}#{n}{/center}\n\n{center}#{spinner[n % 4]}{/center}"
  n += 1
end

s.exec
