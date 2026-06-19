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

    # Neutral RGB values substituted for a "default" color when it has to be
    # mixed with a concrete one (the real terminal default is unknown to us).
    DEFAULT_FG_RGB = 0xc0c0c0
    DEFAULT_BG_RGB = 0x000000

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
        a = Attr.default?(field) ? (fg ? DEFAULT_FG_RGB : DEFAULT_BG_RGB) : field.to_i32
        b = Attr.default?(other) ? (fg ? DEFAULT_FG_RGB : DEFAULT_BG_RGB) : other.to_i32
        Attr.pack_color(mix(a, b, alpha))
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
    BOLD      = 1
    UNDERLINE = 2
    BLINK     = 4
    INVERSE   = 8
    INVISIBLE = 16

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
