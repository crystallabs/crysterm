# FEATURE: sub-cell glyph images (braille, octant, sextant, quadrant).
#
# The `Media::Glyph` family packs several image pixels into every terminal
# cell using Unicode sub-cell glyphs: braille dots and octants give a 2x4
# sub-grid per cell (8x the resolution of plain cells), sextants 2x3 and
# quadrants 2x2. Normally the finest grid the terminal's font supports is
# picked automatically (`--media-backend=auto`); each panel here forces one
# variant so the resolutions can be compared on the same image.

require "../../src/crysterm"

alias CT = Crysterm
alias CW = CT::Widgets

s = CT::Window.new title: "Media: sub-cell glyphs"

img = "#{__DIR__}/../../data/image/matterhorn.png"

CW::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Sub-cell glyph images · auto-picked (--media-backend=auto) · forced per panel{/center}",
  parse_tags: true, style: CT::Style.new(fg: "white", bg: "#202830")

half = s.awidth // 2
row_h = (s.aheight - 2) // 2

[
  {CW::Media::Type::GlyphBraille, "glyph_braille", "2x4"},
  {CW::Media::Type::GlyphOctant, "glyph_octant", "2x4"},
  {CW::Media::Type::GlyphSextant, "glyph_sextant", "2x3"},
  {CW::Media::Type::GlyphQuadrant, "glyph_quadrant", "2x2"},
].each_with_index do |(type, name, sub), i|
  CW::Media.new \
    parent: s, type: type, file: img, fit: CW::Media::Fit::Contain,
    top: 1 + (i // 2) * row_h, left: (i % 2) * half, width: half, height: row_h,
    label: " #{name} · #{sub} sub-pixels ",
    style: CT::Style.new(border: true)
end

CW::Box.new \
  parent: s, top: s.aheight - 1, left: 0, width: "100%", height: 1,
  content: "{center}same PNG in every panel · fit: contain · N x M sub-pixels per terminal cell{/center}",
  parse_tags: true, style: CT::Style.new(fg: "#8090a0")

s.exec
