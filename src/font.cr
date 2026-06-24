require "json"

module Crysterm
  # A bitmap (pixel) font loaded from the JSON format produced by ttystudio
  # (https://github.com/chjj/ttystudio) — the very files `Widget::BigText` uses.
  #
  # Each glyph is a `height`×`width` grid of `0`/`1` (`1` = lit pixel). The
  # capture rasterizer (`Crysterm::Capture`) uses it to draw the screen's
  # text cells as real pixels, so a capture works regardless of the actual
  # terminal font (the output is a fixed, deterministic bitmap-font rendering).
  #
  # Loaded fonts are cached per path (`Font.load`), so the default Terminus
  # faces are parsed at most once per process.
  class Font
    DEFAULT_NORMAL_PATH = "#{__DIR__}/../data/font/ter-u14n.json"
    DEFAULT_BOLD_PATH   = "#{__DIR__}/../data/font/ter-u14b.json"

    @@cache = {} of String => Font

    # Glyph cell size in pixels (e.g. 8×14 for Terminus u14).
    getter width : Int32
    getter height : Int32
    getter glyphs : Hash(String, Array(Array(Int32)))

    # Loads (and memoizes) the font at *path*.
    def self.load(path : String) : Font
      @@cache[path] ||= new(path)
    end

    # The bundled Terminus normal/bold faces.
    def self.default_normal : Font
      load DEFAULT_NORMAL_PATH
    end

    def self.default_bold : Font
      load DEFAULT_BOLD_PATH
    end

    def initialize(path : String)
      data = JSON.parse File.read path
      @width = data["width"].as_i
      @height = data["height"].as_i
      @glyphs = {} of String => Array(Array(Int32))
      data["glyphs"].as_h.each do |ch, g|
        @glyphs[ch] = convert g["map"].as_a.map(&.as_s)
      end
    end

    # The 0/1 pixel grid for *grapheme*, falling back to `"?"` then to blank
    # (a space, or an unknown glyph the font doesn't define).
    def glyph(grapheme : String) : Array(Array(Int32))
      @glyphs[grapheme]? || @glyphs["?"]? || blank
    end

    # Normalizes a JSON glyph `map` (rows of text where any non-space is a lit
    # pixel) into a `height`×`width` 0/1 grid — same trimming/padding as
    # `Widget::BigText#convert_letter`.
    private def convert(lines : Array(String)) : Array(Array(Int32))
      rows = lines.dup
      while rows.size > @height
        rows.shift
        rows.pop
      end
      grid = rows.map do |line|
        cells = line.chars.map { |c| c == ' ' ? 0 : 1 }
        while cells.size < @width
          cells << 0
        end
        cells
      end
      while grid.size < @height
        grid << Array.new(@width, 0)
      end
      grid
    end

    private def blank : Array(Array(Int32))
      Array.new(@height) { Array.new(@width, 0) }
    end
  end
end
