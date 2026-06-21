# FEATURE: Unicode / grapheme-aware rendering.
#
# Crysterm measures terminal column width with wcwidth rules, keeps grapheme
# clusters intact, and (in full_unicode mode) treats wide characters as two
# cells. Box borders are drawn with Unicode line-drawing glyphs.

require "../../src/crysterm"

include Crysterm

s = Screen.new title: "Unicode", force_unicode: true, full_unicode: true
s.show_fps = nil

Widget::Box.new \
  parent: s,
  top: 0, left: 0, width: "100%", height: 3,
  content: "{center}Unicode & grapheme-aware rendering{/center}\n" \
           "{center}Box-drawing, block elements, scripts and combining marks.{/center}",
  parse_tags: true,
  style: Style.new(fg: "white", bg: "#283018", border: true)

Widget::Box.new \
  parent: s,
  top: 4, left: 2, width: 36, height: 8,
  content: "Scripts:\n" \
           "  Ελληνικά  Кириллица  Ãçčénts\n" \
           "Symbols:\n" \
           "  → ← ↑ ↓ ★ ☆ ♥ ♦ ♣ ♠ ✓ ✗ λ ∑ ∞\n" \
           "Combining:\n" \
           "  á ê õ ñ ü  (a´ e^ o~ n~ u¨)",
  parse_tags: true,
  style: Style.new(fg: "yellow", bg: "#101010", border: true)

# Animated block-element bar graph: a `Widget::Graph::BlockBar` draws each value
# as a vertical bar using the eighth-block glyphs (▁▂▃▄▅▆▇█) for sub-cell height.
bars = Widget::Graph::BlockBar.new \
  parent: s,
  top: 4, left: 40, width: 36, height: 8,
  label: " Block elements ", min: 0.0, max: 1.0,
  style: Style.new(fg: "cyan", bg: "#101010", border: true)

phase = 0.0
s.every(0.08.seconds) do
  bars.values = Array.new(32) { |i| Math.sin(phase + i * 0.4) * 0.5 + 0.5 }
  phase += 0.3
end

s.exec
