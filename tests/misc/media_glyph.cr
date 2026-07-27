# FEATURE: sub-cell glyph images (braille, octant, sextant, quadrant).
#
# The `Media::Glyph` family packs several image pixels into every terminal
# cell using Unicode sub-cell glyphs: braille dots and octants give a 2x4
# sub-grid per cell (8x the resolution of plain cells), sextants 2x3 and
# quadrants 2x2. Normally the finest grid the terminal's font supports is
# picked automatically (`--media-backend=auto`); each panel here forces one
# variant so the resolutions can be compared on the same image.

require "../../src/crysterm"

include Crysterm

s = Window.new title: "Media: sub-cell glyphs"

img = "#{__DIR__}/../../data/image/matterhorn.png"

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Sub-cell glyph images · auto-picked (--media-backend=auto) · forced per panel{/center}",
  parse_tags: true, style: Style.new(fg: "white", bg: "#202830")

half = s.awidth // 2
row_h = (s.aheight - 2) // 2

[
  {Widget::Media::Type::GlyphBraille, "glyph_braille", "2x4"},
  {Widget::Media::Type::GlyphOctant, "glyph_octant", "2x4"},
  {Widget::Media::Type::GlyphSextant, "glyph_sextant", "2x3"},
  {Widget::Media::Type::GlyphQuadrant, "glyph_quadrant", "2x2"},
].each_with_index do |(type, name, sub), i|
  Widget::Media.new \
    parent: s, type: type, file: img, fit: Widget::Media::Fit::Contain,
    top: 1 + (i // 2) * row_h, left: (i % 2) * half, width: half, height: row_h,
    label: " #{name} · #{sub} sub-pixels ",
    style: Style.new(border: true)
end

Widget::Box.new \
  parent: s, top: s.aheight - 1, left: 0, width: "100%", height: 1,
  content: "{center}same PNG in every panel · fit: contain · N x M sub-pixels per terminal cell{/center}",
  parse_tags: true, style: Style.new(fg: "#8090a0")

s.exec
