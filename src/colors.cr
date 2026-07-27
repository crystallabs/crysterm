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
  # the terminal cannot do TrueColor.
  module Colors
    extend ::TermColors

    # Cache for `convert(String)` results, keyed by the color spec.
    @@convert_cache = Cache::Bounded(String, Int32).new(Cache::COLOR_CAPACITY, "colors", register: true)

    # Allocation-free cached form of `convert` for color *strings*. Non-`String`
    # specs resolve cheaply through `convert` and are not cached.
    def self.convert_cached(color : String) : Int32
      @@convert_cache.fetch(color) { safe_convert(color) }
    end

    # :ditto:
    def self.convert_cached(color) : Int32
      safe_convert(color)
    end

    # Whether *spec* names a color `convert_cached` recognizes — i.e. it doesn't
    # collapse to the `-1` "unknown" sentinel. Centralizes the one place that
    # knows `-1` means unknown, so the sentinel test isn't re-encoded (with the
    # polarity flipped each way) across the stylesheet layer's color guards.
    @[AlwaysInline]
    def self.known?(spec : String) : Bool
      convert_cached(spec) != -1
    end

    # Coerces a color spec into Crysterm's native `Int32` color space: a color
    # name/`"#rrggbb"` `String` goes through the cached converter, while an
    # already-native `Int32` is returned as-is (identity — *not* re-converted, so
    # a palette-index-looking value is preserved). Centralizes the
    # `x.is_a?(String) ? convert_cached(x) : x` guard hand-written across the
    # widget/text/style layers.
    def self.to_native(color : Int32 | String) : Int32
      color.is_a?(String) ? convert_cached(color) : color
    end

    # :ditto: `nil` (an unset color) passes through unchanged, so a nilable call
    # site can coerce without an outer nil guard.
    def self.to_native(color : Nil) : Nil
      nil
    end

    # `convert`, with an unparseable spec mapped to the `-1` "unknown" sentinel
    # instead of raising, so a malformed stylesheet value can't crash the renderer.
    private def self.safe_convert(color) : Int32
      convert(color).to_i32
    rescue ArgumentError
      -1
    end

    # NOTE: `hex`, `rgb`, `rgb_channels`, `lighter`/`darker`, `sgr_color_to`,
    # `HSV_LUT` and alpha-hex/case-insensitive spec parsing all live in the
    # term_colors shard now (this module `extend`s it); the local copies that
    # used to shadow or extend them are gone. `extend` shares methods but not
    # constants, hence the explicit constant alias:
    HSV_LUT = ::TermColors::HSV_LUT

    # Neutral RGB values substituted for a "default" color when it has to be
    # mixed with a concrete one (the real terminal default is unknown to us).
    def self.default_fg_rgb : Int32
      Crysterm::Config.colors_default_fg
    end

    def self.default_bg_rgb : Int32
      Crysterm::Config.colors_default_bg
    end

    # Resolves a packed color field to a concrete `0xRRGGBB` value, substituting
    # the configured terminal default for a `default` field. Returns `-1` when
    # the field is a still-unknown default (`default_fg/bg_rgb == -1`).
    @[AlwaysInline]
    private def self.resolve_field(field : Int64, fg : Bool) : Int32
      Attr.default?(field) ? (fg ? default_fg_rgb : default_bg_rgb) : field.to_i32
    end

    # Resolves a *logical* color (`-1` default, or `0xRRGGBB`) to a concrete
    # `0xRRGGBB`, substituting the configured terminal default for a `-1`
    # default. Returns `nil` when the color is a still-unknown default
    # (`default_fg/bg_rgb == -1`) — i.e. unresolvable. The `Int32`/`0xRRGGBB`
    # counterpart of the private `resolve_field`, for callers working in logical
    # color space (animation tweens) rather than packed attr fields.
    def self.resolve(color : Int32, fg : Bool) : Int32?
      return color unless color == -1
      d = fg ? default_fg_rgb : default_bg_rgb
      d == -1 ? nil : d
    end

    # Blends two packed color fields in RGB space (`alpha` = weight of *field*
    # over *other*), resolving defaults first and short-circuiting the unknowns:
    # both-default stays `default`, and a single unknown side (`-1`) falls back
    # to the other. Returns a packed color field.
    @[AlwaysInline]
    private def self.blend_fields(field : Int64, other : Int64, fg : Bool, alpha) : Int64
      return Attr::COLOR_DEFAULT if Attr.default?(field) && Attr.default?(other)
      a = resolve_field(field, fg)
      b = resolve_field(other, fg)
      return Attr.pack_color(a == -1 ? b : a) if a == -1 || b == -1
      Attr.pack_color(mix(a, b, alpha))
    end

    # Mixes two *logical* colors (`-1` default, or `0xRRGGBB`) in RGB space
    # (`alpha` = weight of *a* over *b*), resolving defaults first and
    # short-circuiting the unknowns: both-default stays `-1`, a single
    # unresolvable side falls back to the other, else the two are mixed. The
    # `Int32`/`0xRRGGBB` counterpart of the private `blend_fields`, so a caller
    # painting logical colors (e.g. gradient stops) never washes a `-1` default
    # through white the way a bare `mix` would (it reads `-1`'s bits as
    # `0xFFFFFF`).
    def self.mix_resolved(a : Int32, b : Int32, alpha : Float64, fg : Bool) : Int32
      return -1 if a == -1 && b == -1
      ra = resolve(a, fg)
      rb = resolve(b, fg)
      return rb || ra || -1 if ra.nil? || rb.nil?
      mix(ra, rb, alpha)
    end

    # Blends the fg and bg of `attr` with those of `attr2` (alpha compositing,
    # `alpha` = opacity of `attr`'s own colors over `attr2`). With no `attr2` it
    # composites `attr` over black (used for shadows, `alpha` = shadow opacity),
    # leaving "default" colors untouched since their real value is unknown.
    # Operates on the packed `Int64` attr.
    def self.blend(attr : Int64, attr2 : Int64? = nil, alpha : Float | Int = 0.5) : Int64
      fg = blend_field(Attr.fg(attr), attr2.try { |a| Attr.fg(a) }, alpha, true)
      bg = blend_field(Attr.bg(attr), attr2.try { |a| Attr.bg(a) }, alpha, false)
      Attr.pack(Attr.flags(attr), fg, bg)
    end

    # Tints the fg and bg of `attr` toward `color` by `alpha` (`0.0` = unchanged,
    # `1.0` = fully `color`). Unlike `#blend`, a "default" field is resolved to
    # the configured terminal default so the overlay is visible there too,
    # unless that default is itself unknown (`-1`). An unknown `color` is a no-op.
    def self.tint(attr : Int64, color : Int32, alpha : Float | Int = 0.5) : Int64
      fg = tint_field(Attr.fg(attr), color, alpha, true)
      bg = tint_field(Attr.bg(attr), color, alpha, false)
      Attr.pack(Attr.flags(attr), fg, bg)
    end

    # Tints a single packed color field toward `color`. Returns a packed field.
    def self.tint_field(field : Int64, color : Int32, alpha, fg : Bool) : Int64
      # Nothing to tint toward; leaving early matters because `mix` would read
      # `-1`'s bits as `0xFFFFFF` and wash the field toward white.
      return field if color == -1
      base = resolve_field(field, fg)
      return field if base == -1 # unknown terminal default: nothing to tint toward
      Attr.pack_color(mix(color, base, alpha))
    end

    # Blends a single packed color field. Returns a packed color field.
    def self.blend_field(field : Int64, other : Int64?, alpha, fg : Bool) : Int64
      if other.nil?
        # Shadow: composite over black, `alpha` = shadow opacity (1.0 = fully
        # black). A default color can't be darkened (unknown value).
        return field if Attr.default? field
        Attr.pack_color(mix(0x000000, field.to_i32, alpha))
      else
        blend_fields(field, other, fg, alpha)
      end
    end

    # Folds *top* over *under* per *top*'s per-channel `Attr::Alpha` modes. The
    # result is a flattened, `Opaque` attr carrying *top*'s flags. Each channel:
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
      # Fast path for the common fully-opaque overlay cell: with both channels
      # `Opaque`, the fold is just `top` with its alpha/reserved bits cleared.
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
        blend_fields(top, under, fg, 0.5)
      in Attr::Alpha::HighContrast
        base = resolve_field(under, fg)
        base == -1 ? top : Attr.pack_color(readable_on(base, 0x101010, 0xf5f5f5))
      end
    end

  end


  # NOTE: the packed cell-attribute word (`module Attr`) lives in src/attr.cr;
  # SGR encode/decode of it lives in src/sgr.cr.
end
