# Renders one image in a single `Widget::Media::Glyph` drawing mode, chosen with
# the GLYPH_MODE environment variable. make-gifs.sh runs this once per mode to
# produce a still PNG of each render variant of the same Matterhorn photo, so
# they can be compared side by side.
#
#   GLYPH_MODE=braille crystal run glyph_mode.cr
#
# Modes: block ascii half quadrant sextant octant braille

require "../../src/crysterm"

include Crysterm

MODES = {
  "block"    => {Widget::Media::Glyph::Mode::Block, "Block  1x1  (one cell per pixel)"},
  "ascii"    => {Widget::Media::Glyph::Mode::Ascii, "ASCII  1x1  (edge-aware contour glyphs)"},
  "half"     => {Widget::Media::Glyph::Mode::Half, "Half-block  1x2  (2 colors/cell)"},
  "quadrant" => {Widget::Media::Glyph::Mode::Quadrant, "Quadrant  2x2  (2 colors/cell)"},
  "sextant"  => {Widget::Media::Glyph::Mode::Sextant, "Sextant  2x3  (2 colors/cell)"},
  "octant"   => {Widget::Media::Glyph::Mode::Octant, "Octant  2x4  (2 colors/cell)"},
  "braille"  => {Widget::Media::Glyph::Mode::Braille, "Braille  2x4 dots  (1 color/cell)"},
}

key = ENV["GLYPH_MODE"]? || "octant"
mode, desc = MODES[key]? || MODES["block"]

s = Screen.new title: "Media::Glyph: #{key}"

iw = s.awidth
ih = s.aheight - 1

Widget::Media::Glyph.new \
  parent: s, top: 1, left: 0, width: iw, height: ih,
  mode: mode, animate: false,
  file: "#{__DIR__}/../../data/image/matterhorn.png"

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Media::Glyph  ·  #{desc}{/center}", parse_tags: true,
  style: Style.new(fg: "white", bg: "#202830")

s.render
s.exec
