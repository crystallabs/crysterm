require "../../src/crysterm"

# Grapheme / full-Unicode demo.
#
# With `full_unicode: true` (on a Unicode-capable terminal) Crysterm measures
# and lays out text by terminal **column width**: wide CJK and emoji occupy two
# columns, combining marks stay in one cell, grapheme clusters are never split
# across a wrap, and alignment/sizing are column-correct.
#
# Run it (optionally `COLORTERM=truecolor`) and resize the window to watch the
# CJK paragraph re-wrap on column boundaries.
module Crysterm
  s = Window.new full_unicode: true

  active = s.full_unicode? ? "ON" : "OFF (terminal lacks Unicode capability)"

  Widget::Box.new(
    parent: s, top: 0, left: 0, width: "100%", height: 1,
    content: " full_unicode: #{active}    (press q to quit) ",
    style: Style.new(bg: "#202020", fg: "#ffffff"),
  )

  # Mixed wide + narrow + emoji, centered — padding accounts for column width.
  Widget::Box.new(
    parent: s, top: 2, left: "center", width: 40, height: 3,
    content: "中文 + emoji 👍🚀🎉 + café",
    align: Tput::AlignFlag::Center,
    style: Style.new(border: true, fg: "#80d0ff"),
  )

  # A CJK paragraph that wraps on column boundaries (never splitting a glyph).
  Widget::Box.new(
    parent: s, top: 6, left: "center", width: 24, height: 7,
    content: "日本語のテキストは全角文字なので、各文字は二桁分の幅を占めます。",
    style: Style.new(border: true, fg: "#ffd080"),
  )

  # Combining marks: each base+mark is a single cell.
  Widget::Box.new(
    parent: s, top: 14, left: "center", width: 40, height: 3,
    content: "combining: é à ö  flag: \u{1F1EF}\u{1F1F5}",
    style: Style.new(border: true, fg: "#a0ffa0"),
  )

  # Smileys and other usual emoji — each is a wide (two-column) grapheme, so the
  # rows stay column-aligned under full_unicode.
  Widget::Box.new(
    parent: s, top: 18, left: "center", width: 40, height: 5,
    content: "😀 😃 😄 😁 😆 😅 😂 🤣 😉 😊\n" \
             "😍 😘 😎 🤔 😴 😭 😡 🥳 😱 🤯\n" \
             "👍 👎 👏 🙏 🎉 🚀 ❤️ 🔥 ✨ ⭐",
    align: Tput::AlignFlag::Center,
    style: Style.new(border: true, fg: "#ffd0e0"),
  )

  # Headless: render once and exit (so `-- --test-auto` does not block).
  if ARGV.includes? "--test-auto"
    s._render
    exit
  end

  s.on(Event::KeyPress) do |e|
    if e.char == 'q' || e.key == Tput::Key::CtrlQ
      s.destroy
      exit
    end
  end

  s.render
  s.exec
end
