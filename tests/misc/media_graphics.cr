# FEATURE: in-band terminal graphics (Sixel, Kitty, iTerm2, ReGIS).
#
# Beyond character cells, Crysterm can hand the terminal *real pixels*: an
# escape sequence embedded in the normal output stream that a capable
# terminal renders as an image — DEC Sixel, the Kitty graphics protocol,
# iTerm2 inline images, or DEC ReGIS vectors. Normally the best protocol the
# terminal supports is picked automatically (`--media-backend=auto`); each
# panel here forces one so all four can be compared on the same image.

require "../../src/crysterm"

alias CT = Crysterm
alias CW = CT::Widgets

s = CT::Window.new title: "Media: terminal graphics"

img = "#{__DIR__}/../../data/image/matterhorn.png"

CW::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}In-band pixel graphics · auto-picked (--media-backend=auto) · forced per panel{/center}",
  parse_tags: true, style: CT::Style.new(fg: "white", bg: "#202830")

half = s.awidth // 2
row_h = (s.aheight - 2) // 2

[
  {CW::Media::Type::Sixel, "sixel"},
  {CW::Media::Type::Kitty, "kitty"},
  {CW::Media::Type::Iterm, "iterm"},
  {CW::Media::Type::Regis, "regis"},
].each_with_index do |(want, name), i|
  # Each panel pins one protocol, but only where the terminal can render it —
  # elsewhere the raw escape payload would print as text, so it soft-falls
  # back to glyphs. Captures always keep the pin (composited in-process).
  type = CW::Media.type_or_fallback(want)
  label = type == want ? " --media-backend=#{name} " : " glyphs · #{name} n/a "
  CW::Media.new \
    parent: s, type: type, file: img, fit: CW::Media::Fit::Contain,
    top: 1 + (i // 2) * row_h, left: (i % 2) * half, width: half, height: row_h,
    label: label,
    style: CT::Style.new(border: true)
end

CW::Box.new \
  parent: s, top: s.aheight - 1, left: 0, width: "100%", height: 1,
  content: "{center}real pixels, drawn by the terminal itself · needs a graphics-capable terminal{/center}",
  parse_tags: true, style: CT::Style.new(fg: "#8090a0")

s.exec
