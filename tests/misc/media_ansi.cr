# FEATURE: ANSI cell-grid images, truecolor down to 8 colors.
#
# The `Media::Ansi` family renders an image as one terminal cell per pixel,
# quantized (with dithering) to the terminal's color capability: 24-bit
# truecolor, the xterm-256 cube, the 16-color ANSI palette, or the base
# 8 colors. Normally the best variant is picked automatically
# (`--media-backend=auto`); each panel here forces one member of the family
# so they can be compared side by side on the same image.

require "../../src/crysterm"

include Crysterm

s = Window.new title: "Media: ANSI cells"

img = "#{__DIR__}/../../data/image/matterhorn.png"

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}ANSI cell images · backend auto-picked (--media-backend=auto) · forced per panel{/center}",
  parse_tags: true, style: Style.new(fg: "white", bg: "#202830")

half = s.awidth // 2
row_h = (s.aheight - 2) // 2

[
  {Widget::Media::Type::AnsiTrueColor, "ansi_true_color"},
  {Widget::Media::Type::AnsiC256, "ansi_c256"},
  {Widget::Media::Type::AnsiC16, "ansi_c16"},
  {Widget::Media::Type::AnsiC8, "ansi_c8"},
].each_with_index do |(type, name), i|
  Widget::Media.new \
    parent: s, type: type, file: img, fit: Widget::Media::Fit::Contain,
    top: 1 + (i // 2) * row_h, left: (i % 2) * half, width: half, height: row_h,
    label: " --media-backend=#{name} ",
    style: Style.new(border: true)
end

Widget::Box.new \
  parent: s, top: s.aheight - 1, left: 0, width: "100%", height: 1,
  content: "{center}same PNG in every panel · fit: contain · 16.7M → 256 → 16 → 8 colors{/center}",
  parse_tags: true, style: Style.new(fg: "#8090a0")

s.exec
