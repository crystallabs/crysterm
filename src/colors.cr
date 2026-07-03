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
  # the terminal cannot do TrueColor (see `Window#colors` / `Attr`).
  module Colors
    extend ::TermColors

    # Cache for `convert(String)` results, keyed by the color spec.
    @@convert_cache = Hash(String, Int32).new

    # Allocation-free cached form of `convert` for color *strings*.
    #
    # `TermColors#convert(String)` allocates (a `gsub` to strip separators plus a
    # substring in `hex_to_rgb`), which still matters for cases that resolve the
    # same *string* color repeatedly (e.g. an effect's configurable color). The
    # set of distinct color strings is small and bounded, so memoizing turns that
    # allocation into a hash lookup.
    #
    # The non-`String` overload covers `nil`/other specs; those resolve cheaply
    # through `convert` and are not cached.
    def self.convert_cached(color : String) : Int32
      @@convert_cache.fetch(color) { @@convert_cache[color] = safe_convert(color) }
    end

    # :ditto:
    def self.convert_cached(color) : Int32
      safe_convert(color)
    end

    # `TermColors#convert` *raises* on a malformed spec (e.g. a stray `#2a79a3,`
    # token left by an unsupported Qt `qlineargradient(...)` value when the CSS
    # parser splits the declaration). Treat anything unparseable as the `-1`
    # "unknown" sentinel so a stylesheet can't crash the renderer; callers skip
    # the token, letting a later real color in the same value win.
    private def self.safe_convert(color) : Int32
      convert(color).to_i32
    rescue ArgumentError
      -1
    end

    # :ditto:
    #
    # `TermColors#convert` only recognizes the `#rgb`/`#rrggbb` hex forms; the
    # 4- and 8-digit alpha forms (`#rgba`/`#rrggbbaa`) would otherwise fall
    # through to the `-1` default. Drop the trailing alpha nibble/byte (as
    # `rgba()`/`hsla()` values already do) and parse the remaining RGB, so
    # `#f00a` == `#f00` and `#11223344` == `#112233`.
    private def self.safe_convert(color : String) : Int32
      color = strip_hex_alpha(color)
      convert(color).to_i32
    rescue ArgumentError
      -1
    end

    # Strips the alpha channel off the two hex-with-alpha forms, returning the
    # plain `#rgb`/`#rrggbb` the shard's parser understands; any other string
    # (named colors, already-alpha-free hex, malformed input) is returned as-is.
    private def self.strip_hex_alpha(color : String) : String
      return color unless color.starts_with?('#')
      case color.size
      when 5 # #rgba -> #rgb
        color[0, 4] if color[1, 4].each_char.all?(&.to_i?(16))
      when 9 # #rrggbbaa -> #rrggbb
        color[0, 7] if color[1, 8].each_char.all?(&.to_i?(16))
      end || color
    end

    # Neutral RGB values substituted for a "default" color when it has to be
    # mixed with a concrete one (the real terminal default is unknown to us).
    # The typed `Config` accessors read a cached handle, so this costs no hash
    # lookup per blend on the per-cell compositing path.
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

    # Tints the fg and bg of `attr` toward `color` by `alpha` (`0.0` = unchanged,
    # `1.0` = fully `color`) — the animatable color-overlay (`style.tint`)
    # counterpart of the shadow blend. Unlike the shadow, which leaves "default"
    # fields untouched, a tint resolves a default field to the configured
    # terminal default so the overlay is visible there too, unless that default
    # is itself unknown (`-1`). An unknown tint `color` (`-1`) is a no-op.
    def self.tint(attr : Int64, color : Int32, alpha : Float | Int = 0.5) : Int64
      fg = tint_field(Attr.fg(attr), color, alpha, true)
      bg = tint_field(Attr.bg(attr), color, alpha, false)
      Attr.pack(Attr.flags(attr), fg, bg)
    end

    # Tints a single packed color field toward `color`. Returns a packed field.
    def self.tint_field(field : Int64, color : Int32, alpha, fg : Bool) : Int64
      # An unknown tint color (`-1`, e.g. an unparsed `style.tint` string stored
      # by `Style#tint=`) has nothing to tint toward; leave the field unchanged.
      # Otherwise `mix` would read `-1`'s bits as `0xFFFFFF` and wash toward
      # white. Mirrors how `#blend_field` leaves a default/unknown field alone.
      return field if color == -1
      base = Attr.default?(field) ? (fg ? default_fg_rgb : default_bg_rgb) : field.to_i32
      return field if base == -1 # unknown terminal default: nothing to tint toward
      # `mix(color, base, alpha)` lands on `color` at alpha 1, `base` at alpha 0
      # (same convention the shadow uses with black; see `#blend_field`).
      Attr.pack_color(mix(color, base, alpha))
    end

    # Blends a single packed color field. Returns a packed color field.
    def self.blend_field(field : Int64, other : Int64?, alpha, fg : Bool) : Int64
      if other.nil?
        # Shadow: composite the cell color over black, with `alpha` as the
        # shadow's opacity (1.0 = fully black, 0.0 = unchanged). A default color
        # can't be darkened (unknown value), so leave it as-is.
        return field if Attr.default? field
        Attr.pack_color(mix(0x000000, field.to_i32, alpha))
      else
        return Attr::COLOR_DEFAULT if Attr.default?(field) && Attr.default?(other)
        dfl = fg ? default_fg_rgb : default_bg_rgb
        a = Attr.default?(field) ? dfl : field.to_i32
        b = Attr.default?(other) ? dfl : other.to_i32
        # An unknown terminal default (`-1`) has no bits to blend — `mix` would
        # read `-1` as `0xFFFFFF` and wash toward white. Fall back to the other
        # side (mirrors `#composite_field`'s Blend branch and `#tint_field`).
        return Attr.pack_color(a == -1 ? b : a) if a == -1 || b == -1
        Attr.pack_color(mix(a, b, alpha))
      end
    end

    # Folds *top* over *under* per *top*'s per-channel `Attr::Alpha` modes — the
    # per-cell operation a plane compositor runs bottom-to-top. The result is a
    # flattened, `Opaque` attr carrying *top*'s flags. Each channel:
    #
    # * `Opaque`       → *top*'s color (the default; identical to a plain overwrite)
    # * `Transparent`  → *under*'s color (*top* contributes nothing)
    # * `Blend`        → 50/50 blend of *top* and *under*
    # * `HighContrast` → near-black/near-white chosen to read against *under*
    #
    # `default` colors are resolved to the configured terminal default for the
    # blend/contrast math, and left `default` only when that is itself unknown.
    # Mask over both channels' 2-bit alpha-mode fields (bits 57..60). Zero iff
    # both channels are `Opaque` — the fully-opaque overlay cell.
    COMPOSITE_ALPHA_MASK = (Attr::ALPHA_MASK << Attr::FG_ALPHA_SHIFT) | (Attr::ALPHA_MASK << Attr::BG_ALPHA_SHIFT)
    # Keeps bits 0..56 (bg + fg + flags), clearing the alpha-mode and reserved
    # bits above them — exactly what `composite` produces for an opaque cell.
    COMPOSITE_KEEP_MASK = (1_i64 << Attr::FG_ALPHA_SHIFT) - 1

    @[AlwaysInline]
    def self.composite(top : Int64, under : Int64) : Int64
      # Fast path for the common fully-opaque overlay cell (a normal solid
      # popup/box plane): when both channels are `Opaque`, the fold is just
      # `top` with its alpha/reserved bits cleared. One mask test then replaces
      # both `composite_field`s and the `pack`.
      return top & COMPOSITE_KEEP_MASK if (top & COMPOSITE_ALPHA_MASK) == 0
      fg = composite_field(Attr.fg_alpha(top), Attr.fg(top), Attr.fg(under), true)
      bg = composite_field(Attr.bg_alpha(top), Attr.bg(top), Attr.bg(under), false)
      Attr.pack(Attr.flags(top), fg, bg)
    end

    # Composites one packed color field of *top* over *under*'s, per *mode*.
    # Returns a packed color field (the result is always `Opaque`).
    @[AlwaysInline]
    def self.composite_field(mode : Attr::Alpha, top : Int64, under : Int64, fg : Bool) : Int64
      case mode
      in Attr::Alpha::Opaque
        top
      in Attr::Alpha::Transparent
        under
      in Attr::Alpha::Blend
        return Attr::COLOR_DEFAULT if Attr.default?(top) && Attr.default?(under)
        dfl = fg ? default_fg_rgb : default_bg_rgb
        a = Attr.default?(top) ? dfl : top.to_i32
        b = Attr.default?(under) ? dfl : under.to_i32
        return Attr.pack_color(a == -1 ? b : a) if a == -1 || b == -1
        Attr.pack_color(mix(a, b, 0.5))
      in Attr::Alpha::HighContrast
        base = Attr.default?(under) ? (fg ? default_fg_rgb : default_bg_rgb) : under.to_i32
        base == -1 ? top : Attr.pack_color(readable_on(base, 0x101010, 0xf5f5f5))
      end
    end

    # NOTE: `hsv_i` (HSV -> packed `0xRRGGBB`) and `hsv` (HSV -> `#rrggbb`
    # string) live in the `TermColors` shard and are reached through
    # `extend ::TermColors` above.

    # Precomputed `hsv_i` for every integer hue `0...360` at full saturation and
    # value (`s = v = 1`). Effects that tint per-cell or per-column by an integer
    # hue (`Effect::Spray`, `Effect::SineScroller`) index this instead of
    # re-running the float chroma math each frame — the callers already reduce
    # their hue with `% 360`, so `HSV_LUT[h]` is bit-identical to `hsv_i(h)`.
    # (Cases with a variable `s`/`v` — e.g. `Effect::Plasma` — or a custom color
    # are unaffected and keep calling `hsv_i`.)
    HSV_LUT = Array(Int32).new(360) { |h| hsv_i(h) }

    # Allocation-free counterpart of `TermColors#sgr_color`: writes the SGR
    # parameter fragment for one color straight into `io` instead of building
    # and returning a fresh `String`. The draw loop emits a color on every
    # attribute change, so integers `to_s` directly into the IO with no
    # intermediate allocation.
    #
    # Mirrors `sgr_color` exactly: `color` is a native color (`-1` default, or
    # `0xRRGGBB`); `fg` selects foreground vs background; the encoding is the
    # richest the terminal's `colors` count allows (TrueColor / 256 / 16 / 8).
    def self.sgr_color_to(io : IO, color : Int, fg : Bool, colors : Int) : Nil
      # A "default" color, or a monochrome target (`colors < 2`, e.g. NO_COLOR /
      # colors.depth=none): emit the terminal's own default instead of mapping
      # to any palette entry.
      if color == -1 || colors < 2
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
  # `Blend`, `Transparent`, `HighContrast`; see `Colors.composite`). `Opaque` is
  # value `0`, so a zero-initialized attr is `Opaque`/`Opaque` (always-replace).
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
    REVERSE   =  8
    INVISIBLE = 16
    ITALIC    = 32
    STRIKE    = 64 # strikethrough (SGR 9)

    # Width of the style-flags field (bits 50..56). The alpha-mode fields sit
    # directly above it (`FG_ALPHA_SHIFT = FLAGS_SHIFT + FLAGS_BITS`), so
    # widening this shifts them up too: 7 flags occupy bits 50..56, fg/bg alpha
    # 57..60, leaving 61..63 free.
    FLAGS_BITS = 7_i64
    FLAGS_MASK = (1_i64 << FLAGS_BITS) - 1 # 0x7F

    # Per-channel alpha *mode*: how a cell's channel combines with the channel
    # beneath it when planes are composited (`Colors.composite`). `Opaque` is
    # value `0`, so a freshly-`pack`ed attr (alpha bits clear) replaces as before.
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

    # Extracts the flags field (masked to its 7 bits, so the alpha modes packed
    # just above it never leak into a flag test or SGR emission).
    @[AlwaysInline]
    def self.flags(attr : Int64) : Int64
      (attr >> FLAGS_SHIFT) & FLAGS_MASK
    end

    # Packs flags + already-packed color fields into an `attr` word. Alpha modes
    # default to `Opaque` (zero); set them afterward with `#with_fg_alpha` etc.
    # `flags` is masked so a stray high bit can't bleed into the alpha fields.
    @[AlwaysInline]
    def self.pack(flags, fg, bg) : Int64
      ((flags.to_i64 & FLAGS_MASK) << FLAGS_SHIFT) | ((fg.to_i64 & COLOR_MASK) << FG_SHIFT) | (bg.to_i64 & COLOR_MASK)
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
