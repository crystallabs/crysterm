module Crysterm
  # Packing/unpacking of a cell's *attribute* word.
  #
  # An attribute (`attr`) bundles a foreground color, a background color, and a
  # set of style flags (bold/underline/blink/reverse/invisible) into a single
  # integer that every cell in the window buffer stores.
  #
  # Each color is a full 24-bit RGB value (plus a "default" marker), so two
  # colors don't fit alongside the flags in an `Int32`; the packed `attr` is an
  # **`Int64`** laid out as:
  #
  # ```text
  #   bits  0..24  : bg        (25 bits: 24-bit RGB, or COLOR_DEFAULT)
  #   bits 25..49  : fg        (25 bits)
  #   bits 50..56  : flags     (7 style bits: bold/underline/blink/reverse/invisible/italic/strikethrough)
  #   bits 57..58  : fg alpha  (2-bit `Alpha` mode for the foreground channel)
  #   bits 59..60  : bg alpha  (2-bit `Alpha` mode for the background channel)
  #   bits 61..63  : reserved
  # ```
  #
  # A *color field* holds either an RGB value (`0..0xFFFFFF`) or the sentinel
  # `COLOR_DEFAULT` meaning "use the terminal's default fg/bg". This is the
  # in-`attr` counterpart of the logical `-1` used by `Colors.convert`.
  #
  # Each channel also carries an `Alpha` *mode* (à la notcurses) saying how it
  # combines with the cell beneath it when planes are composited (`Opaque`,
  # `Blend`, `Transparent`, `HighContrast`). `Opaque` is value `0`, so a
  # zero-initialized attr is `Opaque`/`Opaque` (always-replace).
  #
  # This module is the single source of truth for the bit layout; nothing else
  # should hard-code shifts or masks. SGR encode/decode of these words lives in
  # `Crysterm::SGR`.
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
    REVERSE   =  8
    INVISIBLE = 16
    ITALIC    = 32
    STRIKE    = 64 # strikethrough (SGR 9)

    # Width of the style-flags field (bits 50..56). The alpha-mode fields are
    # derived from it, so widening this shifts them up too; bits 61..63 are free.
    FLAGS_BITS = 7_i64
    FLAGS_MASK = (1_i64 << FLAGS_BITS) - 1 # 0x7F

    # Per-channel alpha *mode*: how a cell's channel combines with the channel
    # beneath it when planes are composited. `Opaque` must stay value `0`, so a
    # freshly-`pack`ed attr (alpha bits clear) replaces rather than blends.
    enum Alpha
      Opaque       # fully replace the channel beneath
      Blend        # blend 50/50 with the channel beneath
      Transparent  # contribute nothing; the channel beneath shows through
      HighContrast # recolor for maximum contrast against the channel beneath
    end

    # Width and offsets of the two 2-bit alpha-mode fields (fg then bg, just
    # above the flags).
    ALPHA_BITS     = 2_i64
    ALPHA_MASK     = (1_i64 << ALPHA_BITS) - 1   # 0x3
    FG_ALPHA_SHIFT = FLAGS_SHIFT + FLAGS_BITS    # 57
    BG_ALPHA_SHIFT = FG_ALPHA_SHIFT + ALPHA_BITS # 59

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

    # Extracts the flags field. Masked to its 7 bits, so the alpha modes packed
    # just above it never leak into a flag test or SGR emission.
    @[AlwaysInline]
    def self.flags(attr : Int64) : Int64
      (attr >> FLAGS_SHIFT) & FLAGS_MASK
    end

    # Packs the seven style-flag booleans into a flag word — the shared spelling
    # of "booleans -> `Attr` flags" used by `Widget.style_to_attr_flags` and
    # `Direct#build_code`, so the flag list exists exactly once.
    @[AlwaysInline]
    def self.flags_of(bold = false, italic = false, underline = false, blink = false,
                      reverse = false, strike = false, invisible = false) : Int64
      (bold ? BOLD.to_i64 : 0_i64) |
        (italic ? ITALIC.to_i64 : 0_i64) |
        (underline ? UNDERLINE.to_i64 : 0_i64) |
        (blink ? BLINK.to_i64 : 0_i64) |
        (reverse ? REVERSE.to_i64 : 0_i64) |
        (strike ? STRIKE.to_i64 : 0_i64) |
        (invisible ? INVISIBLE.to_i64 : 0_i64)
    end

    # Packs flags + already-packed color fields into an `attr` word. Alpha modes
    # default to `Opaque` (zero); set them afterward with `#with_fg_alpha` etc.
    # `flags` is masked so a stray high bit can't bleed into the alpha fields.
    @[AlwaysInline]
    def self.pack(flags, fg, bg) : Int64
      ((flags.to_i64 & FLAGS_MASK) << FLAGS_SHIFT) | ((fg.to_i64 & COLOR_MASK) << FG_SHIFT) | (bg.to_i64 & COLOR_MASK)
    end

    # Returns *base* with only its foreground color field replaced by the
    # already-packed color field *packed_fg* (flags, bg, and alpha preserved).
    @[AlwaysInline]
    def self.with_fg(base : Int64, packed_fg : Int64) : Int64
      (base & ~(COLOR_MASK << FG_SHIFT)) | ((packed_fg & COLOR_MASK) << FG_SHIFT)
    end

    # Returns *base* with only its background color field replaced by the
    # already-packed color field *packed_bg* (flags, fg, and alpha preserved).
    @[AlwaysInline]
    def self.with_bg(base : Int64, packed_bg : Int64) : Int64
      (base & ~COLOR_MASK) | (packed_bg & COLOR_MASK)
    end

    # The foreground channel's alpha mode.
    @[AlwaysInline]
    def self.fg_alpha(attr : Int64) : Alpha
      Alpha.new(((attr >> FG_ALPHA_SHIFT) & ALPHA_MASK).to_i32)
    end

    # The background channel's alpha mode.
    @[AlwaysInline]
    def self.bg_alpha(attr : Int64) : Alpha
      Alpha.new(((attr >> BG_ALPHA_SHIFT) & ALPHA_MASK).to_i32)
    end

    # Returns *attr* with the foreground alpha mode set to *mode*.
    @[AlwaysInline]
    def self.with_fg_alpha(attr : Int64, mode : Alpha) : Int64
      (attr & ~(ALPHA_MASK << FG_ALPHA_SHIFT)) | (mode.value.to_i64 << FG_ALPHA_SHIFT)
    end

    # Returns *attr* with the background alpha mode set to *mode*.
    @[AlwaysInline]
    def self.with_bg_alpha(attr : Int64, mode : Alpha) : Int64
      (attr & ~(ALPHA_MASK << BG_ALPHA_SHIFT)) | (mode.value.to_i64 << BG_ALPHA_SHIFT)
    end

    # Returns *attr* with both channels' alpha modes set.
    @[AlwaysInline]
    def self.with_alpha(attr : Int64, fg : Alpha, bg : Alpha) : Int64
      with_bg_alpha(with_fg_alpha(attr, fg), bg)
    end
  end
end
