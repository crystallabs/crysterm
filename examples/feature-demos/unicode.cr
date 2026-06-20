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

# Animated block-element bar graph (uses ▁▂▃▄▅▆▇█).
bars = Widget::Box.new \
  parent: s,
  top: 4, left: 40, width: 36, height: 8,
  content: "",
  style: Style.new(fg: "cyan", bg: "#101010", border: true)

blocks = " ▁▂▃▄▅▆▇█".chars

s.on(Event::KeyPress) do |e|
  if e.char == 'q' || e.key == Tput::Key::CtrlQ
    s.destroy
    exit
  end
end

phase = 0.0
spawn do
  loop do
    lines = [] of String
    4.times do |row|
      line = String.build do |io|
        30.times do |i|
          v = (Math.sin(phase + i * 0.4 + row) * 0.5 + 0.5) * (blocks.size - 1)
          io << blocks[v.to_i]
        end
      end
      lines << line
    end
    bars.content = "Block elements:\n" + lines.join("\n")
    phase += 0.3
    s.render
    sleep 0.08.seconds
  end
end

s.exec
