require "term_colors"

module Crysterm
  # Color-related functionality.
  #
  # Crysterm's native color space is **TrueColor (24-bit RGB)**. A color is an
  # `Int32`: `-1` means "terminal default", and `0x000000`..`0xFFFFFF` is a
  # 24-bit RGB value. Colors specified as names ("blue") or hex strings
  # ("#0000ff") are parsed into this native form by `Colors.convert` (provided
  # by the `TermColors` shard).
  #
  # Colors are only reduced to 256/16/8/2 colors at output time, and only when
  # the terminal cannot do TrueColor (see `Screen#colors` / `Attr`).
  module Colors
    extend ::TermColors

    # Cache for `convert(String)` results, keyed by the color spec.
    @@convert_cache = Hash(String, Int32).new

    # Allocation-free cached form of `convert` for color *strings*.
    #
    # Colors are now stored natively (as `0xRRGGBB` ints), so the render hot
    # path (`sattr`) no longer parses strings per frame. This memoizer remains
    # for the cases that still resolve a *string* color repeatedly — e.g. an
    # effect whose configurable color is supplied as a string — since
    # `TermColors#convert(String)` allocates (a `gsub` to strip separators plus a
    # substring in `hex_to_rgb`). The set of distinct color strings an
    # application uses is small and bounded, so memoizing turns that garbage into
    # an allocation-free hash lookup.
    #
    # The non-`String` overload covers `nil`/other specs; those resolve cheaply
    # through `convert` and are not cached.
    def self.convert_cached(color : String) : Int32
      @@convert_cache.fetch(color) { @@convert_cache[color] = convert(color).to_i32 }
    end

    # :ditto:
    def self.convert_cached(color) : Int32
      convert(color).to_i32
    end

    # Neutral RGB values substituted for a "default" color when it has to be
    # mixed with a concrete one (the real terminal default is unknown to us).
    # The typed `Config` accessors read a cached handle, so this stays
    # runtime-tunable yet costs no hash lookup per blend — and blending is on
    # the per-cell compositing path.
    def self.default_fg_rgb : Int32
      Crysterm::Config.colors_default_fg
    end

    def self.default_bg_rgb : Int32
      Crysterm::Config.colors_default_bg
    end

    # Blends the fg and bg of `attr` with those of `attr2` (alpha compositing,
    # `alpha` = opacity of `attr`'s own colors over `attr2`). With no `attr2` it
    # composites `attr` over black (used for shadows, `alpha` = shadow opacity),
    # leaving "default" colors untouched since their real value is unknown.
    # Operates on the packed `Int64` attr.
    #
    # Replaces the old palette-index `TermColors#blend`; per-channel mixing is
    # delegated to `TermColors#mix` (RGB space).
    def self.blend(attr : Int64, attr2 : Int64? = nil, alpha : Float | Int = 0.5) : Int64
      fg = blend_field(Attr.fg(attr), attr2.try { |a| Attr.fg(a) }, alpha, true)
      bg = blend_field(Attr.bg(attr), attr2.try { |a| Attr.bg(a) }, alpha, false)
      Attr.pack(Attr.flags(attr), fg, bg)
    end

    # Blends a single packed color field. Returns a packed color field.
    def self.blend_field(field : Int64, other : Int64?, alpha, fg : Bool) : Int64
      if other.nil?
        # Shadow: composite the cell color over black, with `alpha` as the
        # shadow's opacity (1.0 = fully black, 0.0 = unchanged). A default color
        # can't be darkened (we don't know its value), so leave it as-is.
        return field if Attr.default? field
        Attr.pack_color(mix(0x000000, field.to_i32, alpha))
      else
        return Attr::COLOR_DEFAULT if Attr.default?(field) && Attr.default?(other)
        dfl = fg ? default_fg_rgb : default_bg_rgb
        a = Attr.default?(field) ? dfl : field.to_i32
        b = Attr.default?(other) ? dfl : other.to_i32
        Attr.pack_color(mix(a, b, alpha))
      end
    end

    # NOTE: `hsv_i` (HSV -> packed `0xRRGGBB`) and `hsv` (HSV -> `#rrggbb`
    # string) now live in the `TermColors` shard (pure color-space math) and are
    # reached through `extend ::TermColors` above, so `Colors.hsv_i`/`Colors.hsv`
    # keep working unchanged.

    # Allocation-free counterpart of `TermColors#sgr_color`: writes the SGR
    # parameter fragment for one color straight into `io` instead of building
    # and returning a fresh `String`. The draw loop emits a color on every
    # attribute change, so the per-call `String` (and its `#{...}`
    # interpolations) is pure garbage; integers `to_s` directly into the IO with
    # no intermediate allocation.
    #
    # Mirrors `sgr_color` exactly: `color` is a native color (`-1` default, or
    # `0xRRGGBB`); `fg` selects foreground vs background; the encoding is the
    # richest the terminal's `colors` count allows (TrueColor / 256 / 16 / 8).
    def self.sgr_color_to(io : IO, color : Int, fg : Bool, colors : Int) : Nil
      if color == -1
        io << (fg ? "39" : "49")
        return
      end

      r = (color >> 16) & 0xff
      g = (color >> 8) & 0xff
      b = color & 0xff

      if colors >= 0x1000000
        io << (fg ? 38 : 48) << ";2;" << r << ';' << g << ';' << b
        return
      end

      idx = reduce(match(r, g, b), colors)
      if idx < 8
        io << (fg ? 30 + idx : 40 + idx)
      elsif idx < 16
        io << (fg ? 90 + (idx - 8) : 100 + (idx - 8))
      else
        io << (fg ? 38 : 48) << ";5;" << idx
      end
    end
  end

  # Packing/unpacking of a cell's *attribute* word.
  #
  # An attribute (`attr`) bundles a foreground color, a background color, and a
  # set of style flags (bold/underline/blink/inverse/invisible) into a single
  # integer that every cell in the screen buffer stores.
  #
  # Because each color is now a full 24-bit RGB value (plus a "default" marker),
  # two colors no longer fit alongside the flags in an `Int32`; the packed
  # `attr` is an **`Int64`** laid out as:
  #
  # ```text
  #   bits  0..24  : bg   (25 bits: 24-bit RGB, or COLOR_DEFAULT)
  #   bits 25..49  : fg   (25 bits)
  #   bits 50..    : flags
  # ```
  #
  # A *color field* holds either an RGB value (`0..0xFFFFFF`) or the sentinel
  # `COLOR_DEFAULT` meaning "use the terminal's default fg/bg". This is the
  # in-`attr` counterpart of the logical `-1` used by `Colors.convert`.
  #
  # This module is the single source of truth for the bit layout; nothing else
  # should hard-code shifts or masks.
  module Attr
    # Width (in bits) of one packed color field: 24 for RGB + 1 for the
    # `COLOR_DEFAULT` sentinel.
    COLOR_BITS = 25_i64

    # Sentinel stored in a color field to mean "terminal default" (the packed
    # equivalent of the logical color `-1`). Sits just above the 24-bit RGB
    # range so it never collides with a real color.
    COLOR_DEFAULT = 0x1000000_i64

    # Mask covering a whole color field (RGB range + the default sentinel).
    COLOR_MASK = (1_i64 << COLOR_BITS) - 1 # 0x1FFFFFF

    # Bit offset of the foreground color field.
    FG_SHIFT = COLOR_BITS # 25

    # Bit offset of the flags field.
    FLAGS_SHIFT = COLOR_BITS * 2 # 50

    # Style flag bits (within the flags field).
    BOLD      =  1
    UNDERLINE =  2
    BLINK     =  4
    INVERSE   =  8
    INVISIBLE = 16
    ITALIC    = 32

    # Maps a *logical* color (`-1` default, or `0xRRGGBB`) to its packed color
    # field value (`COLOR_DEFAULT`, or the RGB value).
    @[AlwaysInline]
    def self.pack_color(c) : Int64
      c == -1 ? COLOR_DEFAULT : (c.to_i64 & 0xFFFFFF)
    end

    # Inverse of `pack_color`: a packed color field back to a logical color
    # (`-1` for default, otherwise the `0xRRGGBB` value).
    @[AlwaysInline]
    def self.unpack_color(field) : Int32
      field == COLOR_DEFAULT ? -1 : (field & 0xFFFFFF).to_i32
    end

    # True when a packed color field is the "terminal default" sentinel.
    @[AlwaysInline]
    def self.default?(field) : Bool
      field == COLOR_DEFAULT
    end

    # Extracts the packed background color field.
    @[AlwaysInline]
    def self.bg(attr : Int64) : Int64
      attr & COLOR_MASK
    end

    # Extracts the packed foreground color field.
    @[AlwaysInline]
    def self.fg(attr : Int64) : Int64
      (attr >> FG_SHIFT) & COLOR_MASK
    end

    # Extracts the flags field.
    @[AlwaysInline]
    def self.flags(attr : Int64) : Int64
      attr >> FLAGS_SHIFT
    end

    # Packs flags + already-packed color fields into an `attr` word.
    @[AlwaysInline]
    def self.pack(flags, fg, bg) : Int64
      (flags.to_i64 << FLAGS_SHIFT) | ((fg.to_i64 & COLOR_MASK) << FG_SHIFT) | (bg.to_i64 & COLOR_MASK)
    end
  end
end
