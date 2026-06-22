# IMPRESSIVE DEMO: "Spray" — glyphs shot from the centre that fly out, grow, and
# land filling the whole screen.
#
# Extracted from the `cracktro` demo's letter-spray, now reusable as
# `Widget::Effect::Spray`. The cell-fill order is pluggable (`fill:`): `:spiral`
# (the cracktro look), `:rows`, `:columns`, `:diagonal`, `:radial`, `:random`,
# or any caller-supplied `(w, h) -> cells` proc.
#
# Like `Effect::Matrix`, it fills its own box, reads its size lazily (tracking
# resize), and drives its own animation fiber — `start` to run, `stop` to halt.

require "../../src/crysterm"

include Crysterm

s = Screen.new title: "CRYSTERM spray"

# Default `pattern` is the DOS dithered block `▒`, so the spiral paints a solid
# shaded fill. Pass e.g. `pattern: "CRYSTERM "` to spell out text instead.
spray = Widget::Effect::Spray.new \
  parent: s, top: 0, left: 0, width: "100%", height: "100%",
  fill: :spiral,
  style: Style.new(bg: "black")

spray.start

s.exec
