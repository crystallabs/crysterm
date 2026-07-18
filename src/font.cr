require "json"

module Crysterm
  # A bitmap (pixel) font used by the capture rasterizer (`Crysterm::Capture`) to
  # draw the window's text cells as real pixels — so a capture is deterministic
  # and independent of the user's actual terminal font.
  #
  # Two on-disk formats are supported, picked by extension:
  #
  # * **`.hex`** — GNU Unifont's format (`CODEPOINT:HEXBITMAP`, 16 px tall, 8 px
  #   wide for half-width glyphs and 16 px for full-width). Default, for its
  #   coverage (Latin, box-drawing, blocks, **Braille**, sextants, **octants**,
  #   … — everything TUI graphics widgets draw with). Glyphs decode lazily, on
  #   first use, so loading the ~100k-glyph file is cheap.
  # * **`.json`** — the ttystudio format (per-glyph pixel `map`), the files
  #   `Widget::BigText` uses.
  #
  # Each glyph resolves to a `height`×`width` grid of `0`/`1` (`1` = lit pixel).
  #
  # Named `BitmapFont`, not `Font`: this is a capture-rasterizer bitmap face,
  # not a text/terminal font — `Font` would squat the more general name.
  class BitmapFont
    # GNU Unifont (all planes) — the default capture face.
    DEFAULT_NORMAL_PATH = "#{__DIR__}/../data/font/unifont.hex"
    DEFAULT_BOLD_PATH   = "#{__DIR__}/../data/font/unifont.hex"

    # Loaded faces, keyed by `path` + weight.
    @@cache = Cache::Bounded(String, BitmapFont).new(Cache::FONT_CAPACITY, "font", register: true)

    # Glyph cell size in pixels (8×16 for Unifont half-width; 8×14 for Terminus).
    getter width : Int32
    getter height : Int32

    # Converted glyph grids, memoized. For `.hex` fonts this starts empty and
    # fills lazily as `#glyph` is called; for `.json` it is built up front.
    getter glyphs : Hash(String, Array(Array(Int32)))

    # Raw `CODEPOINT -> hex bitmap` map for `.hex` fonts (nil for `.json`).
    @hex : Hash(String, String)?
    # Render synthetic bold (smear each row 1 px right) — `.hex` has no bold face.
    @bold : Bool

    # Loads (and memoizes) the font at *path*. *bold* synthesizes a bold variant
    # for `.hex` faces (which ship only one weight).
    def self.load(path : String, bold : Bool = false) : BitmapFont
      @@cache.fetch("#{path}#{bold ? "#b" : ""}") { new(path, bold) }
    end

    # The default normal/bold faces (GNU Unifont; bold is synthesized).
    def self.default_normal : BitmapFont
      load DEFAULT_NORMAL_PATH
    end

    def self.default_bold : BitmapFont
      load DEFAULT_BOLD_PATH, bold: true
    end

    def initialize(path : String, @bold : Bool = false)
      @glyphs = {} of String => Array(Array(Int32))
      @hex = nil
      if path.ends_with?(".hex")
        @width, @height = 8, 16
        load_hex path
      else
        @width, @height = load_json path
      end
    end

    # Index a Unifont `.hex` file as `char -> hex bitmap` (decoded on demand).
    private def load_hex(path : String) : Nil
      map = {} of String => String
      File.each_line(path) do |line|
        next if line.empty?
        colon = line.index(':')
        next unless colon
        cp = line[0...colon].to_i?(16)
        next unless cp && cp <= 0x10FFFF && !(0xD800 <= cp <= 0xDFFF)
        map[cp.chr.to_s] = line[(colon + 1)..]
      end
      @hex = map
    end

    private def load_json(path : String) : {Int32, Int32}
      data = JSON.parse File.read path
      w = data["width"].as_i
      h = data["height"].as_i
      data["glyphs"].as_h.each do |ch, g|
        @glyphs[ch] = convert g["map"].as_a.map(&.as_s), w, h
      end
      {w, h}
    end

    # The 0/1 pixel grid for *grapheme*, falling back to `"?"` then to blank.
    # The resolved grid (including a fallback) is cached under *grapheme*, so a
    # repeated miss is a single hash hit rather than a re-decode + fresh blank.
    def glyph(grapheme : String) : Array(Array(Int32))
      @glyphs[grapheme] ||= (cached_or_decode(grapheme) || cached_or_decode("?") || blank)
    end

    private def cached_or_decode(grapheme : String) : Array(Array(Int32))?
      @glyphs[grapheme]? || begin
        hx = @hex.try &.[grapheme]?
        hx ? (@glyphs[grapheme] = decode_hex(hx)) : nil
      end
    end

    # Expand a Unifont hex bitmap to a `height`×width 0/1 grid (width = 8 or 16,
    # taken from row length). Synthesizes bold by OR-ing each row with itself
    # shifted right one pixel.
    private def decode_hex(hex : String) : Array(Array(Int32))
      per_row = hex.size // @height # hex digits per row (2 -> 8px, 4 -> 16px)
      return blank if per_row == 0
      w = per_row * 4
      Array(Array(Int32)).new(@height) do |r|
        # `to_u32?` (not strict `to_u32`): a corrupt `.hex` font can carry a
        # non-hex bitmap payload (`0041:ZZ...`), which would raise mid-capture.
        # An unparseable row is all-off.
        bits = hex[r * per_row, per_row].to_u32?(16) || 0_u32
        bits |= bits >> 1 if @bold
        Array(Int32).new(w) { |c| ((bits >> (w - 1 - c)) & 1).to_i }
      end
    end

    # Normalizes a ttystudio glyph `map` (rows of text; any non-space = lit) into
    # an *h*×*w* 0/1 grid.
    private def convert(lines : Array(String), w : Int32, h : Int32) : Array(Array(Int32))
      rows = lines.dup
      # Center-crop toward *h* rows, removing from top and bottom. The guarded
      # bottom `pop` keeps a single excess row from dropping two and undershooting.
      while rows.size > h
        rows.shift
        rows.pop if rows.size > h
      end
      grid = rows.map do |line|
        cells = line.chars.map { |c| c == ' ' ? 0 : 1 }
        while cells.size < w
          cells << 0
        end
        cells
      end
      while grid.size < h
        grid << Array.new(w, 0)
      end
      grid
    end

    # Shared, memoized all-zero fallback grid. Safe to hand out repeatedly:
    # callers only read glyph grids, never mutate them.
    @blank : Array(Array(Int32))?

    private def blank : Array(Array(Int32))
      @blank ||= Array.new(@height) { Array.new(@width, 0) }
    end
  end
end
