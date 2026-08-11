module Crysterm
  # A widget's drop shadow.
  class Shadow
    include SidedGeometry

    # A fresh zero shadow ("no shadow": all sides 0). Must never be a shared
    # singleton: `Shadow` is mutable and every `Style` gets one, so a shared
    # instance would let one style's edit leak into all others.
    def self.default : Shadow
      new 0, 0, 0, 0
    end

    # Per-side extents: `left`/`right` are widths, `top`/`bottom` heights. The
    # resting defaults are asymmetric — a classic right/bottom drop shadow
    # (`right: 2, bottom: 1`, none on the left/top).
    SidedGeometry.sided_int_properties right: 2, bottom: 1

    # Shadow opacity value (0 == full transparency, 1 == full opacity)
    property opacity : Float64 = 0.5

    # Thickness of a *thin* shadow, as a fraction of the cell width — the same
    # unit and aspect compensation as `Border#ratio`, resolved through the
    # shared block-ink tables (`Glyphs::SeqRole::BorderRamp*`). Set, each band
    # derives its half-block glyph automatically: the shadow tone hugs the
    # widget edge at this thickness and the glyph paints the untouched
    # backdrop over the cell remainder (see `#glyph_octet` and
    # `Window#blend_region`), so `Shadow.new(right: 1, bottom: 1, ratio: :half)`
    # replaces hand-picking `▄`/`▐` per side. A band whose ink consumes its
    # whole cell derives no glyph and degrades to the classic full-cell blend
    # — at `1.0` (a full column) that's the left/right bands, while top/bottom
    # ink the on-screen equivalent, half a cell. `nil` (the default) leaves
    # only explicitly set chars in effect.
    property ratio : Float64? = nil

    # Sets `#ratio` by named preset: `:thin` (an eighth), `:quarter`, `:half`,
    # `:full` (see `Glyphs::BLOCK_RATIOS`).
    def ratio=(name : Symbol)
      @ratio = Glyphs::BLOCK_RATIOS[name.to_s]? ||
               raise ArgumentError.new "Unknown shadow ratio #{name.inspect} (known: #{Glyphs::BLOCK_RATIOS.keys.join(", ")})"
    end

    # Optional glyphs used to paint a *thin* shadow: a band with a glyph set is
    # drawn with that half-block character rather than by darkening the whole
    # cell, so the shadow occupies only part of a cell. `nil` (the default) keeps
    # the classic full-cell alpha-blended shadow.
    #
    # The shadow tone is the cell *background* and the glyph's foreground carries
    # the untouched backdrop over the other half, so pick the glyph whose *solid*
    # half faces away from the widget: `▄` shadows the top half (a bottom-edge
    # shadow), `▀` the bottom, `▐` the left half (a right-edge shadow), `▌` the
    # right. Eight glyphs are selectable — four sides, four corners — since a
    # cell's height and width differ; each resolves through the group fallbacks
    # below, so you set only what differs.
    property horizontal_char : Char? = nil
    property vertical_char : Char? = nil
    property diagonal_char : Char? = nil

    @top_char : Char? = nil
    @bottom_char : Char? = nil
    @left_char : Char? = nil
    @right_char : Char? = nil
    @top_left_char : Char? = nil
    @top_right_char : Char? = nil
    @bottom_left_char : Char? = nil
    @bottom_right_char : Char? = nil

    # Per-side/per-corner overrides; each falls back to its group default above.
    setter top_char, bottom_char, left_char, right_char
    setter top_left_char, top_right_char, bottom_left_char, bottom_right_char

    # The top/bottom run glyphs (override or the `horizontal_char` axis default).
    def top_char : Char?
      @top_char || @horizontal_char
    end

    # :ditto:
    def bottom_char : Char?
      @bottom_char || @horizontal_char
    end

    # The left/right run glyphs (override or the `vertical_char` axis default).
    def left_char : Char?
      @left_char || @vertical_char
    end

    # :ditto:
    def right_char : Char?
      @right_char || @vertical_char
    end

    # The corner (diagonal) glyphs, each falling back to `diagonal_char` and then
    # to `horizontal_char` — the run along the merge line between the two bands.
    def top_left_char : Char?
      @top_left_char || @diagonal_char || @horizontal_char
    end

    # :ditto:
    def top_right_char : Char?
      @top_right_char || @diagonal_char || @horizontal_char
    end

    # :ditto:
    def bottom_left_char : Char?
      @bottom_left_char || @diagonal_char || @horizontal_char
    end

    # :ditto:
    def bottom_right_char : Char?
      @bottom_right_char || @diagonal_char || @horizontal_char
    end

    # Whether any half-block glyph is configured (any group, side or corner)
    # or a `ratio` derives them. When false the shadow is a plain full-cell
    # alpha blend, which the renderer paints on a faster, undivided path.
    def glyphs? : Bool
      return true if @ratio
      !SidedGeometry.all_nil?(horizontal_char, vertical_char, diagonal_char,
        top_char, bottom_char, left_char, right_char,
        top_left_char, top_right_char, bottom_left_char, bottom_right_char)
    end

    # The eight glyphs of a thin shadow at *tier* — one per band run and
    # corner, `nil` where that band alpha-blends its full cells. Explicit char
    # overrides win; the rest derive from `#ratio` (when set) out of the
    # shared block-ink tables, in the *complement* encoding `Window#blend_region`
    # paints: the cell background carries the shadow tone (a bg fill always
    # reaches the cell edges, so the band hugs the widget with no hairline
    # gap), while the glyph — anchored *away* from the widget — restores the
    # untouched backdrop over the remainder. So a band `n/8` thick draws the
    # `(8-n)/8` ground glyph of the opposite anchor, and a corner draws the
    # elbow hugging its away-facing cell corner.
    def glyph_octet(tier : Glyphs::Tier)
      dt = db = dl = dr = dtl = dtr = dbl = dbr = nil.as(Char?)
      if r = @ratio
        w8, v8 = Glyphs.block_eighths(r)
        # Ground steps (the glyph's share of the cell). 0 = no glyph left:
        # the band degrades to the classic full-cell blend.
        gv, gw = 8 - v8, 8 - w8
        # Vertical bands hug the widget's top/bottom edge, so their ground
        # anchors at the cell edge away from it — a bottom band's ground is
        # the *lower*-anchored ramp, etc. The upper/right ramps only offer
        # 1/8, 4/8 and 8/8 at the non-`extended` tiers, and the 8/8 full
        # block would erase the band entirely — cap those two at the 4/8 step
        # (nearest visible) instead.
        cap = tier.extended? ? 8 : 5
        db = gv.zero? ? nil : Glyphs.chars(Glyphs::SeqRole::BorderRampLower, tier)[gv - 1]
        dt = gv.zero? ? nil : Glyphs.chars(Glyphs::SeqRole::BorderRampUpper, tier)[Math.min(gv, cap) - 1]
        dr = gw.zero? ? nil : Glyphs.chars(Glyphs::SeqRole::BorderRampRight, tier)[Math.min(gw, cap) - 1]
        dl = gw.zero? ? nil : Glyphs.chars(Glyphs::SeqRole::BorderRampLeft, tier)[gw - 1]
        # Corner ground: the elbow anchored at the band corner's own (away)
        # cell corner, stepped by the thicker arm's complement — clamped
        # below the full-block bucket, which would erase the corner.
        gc = 8 - Math.max(w8, v8)
        unless gc.zero?
          ci = gc.clamp(1, 5) - 1
          dtl = Glyphs.chars(Glyphs::SeqRole::BorderElbowTL, tier)[ci]
          dtr = Glyphs.chars(Glyphs::SeqRole::BorderElbowTR, tier)[ci]
          dbl = Glyphs.chars(Glyphs::SeqRole::BorderElbowBL, tier)[ci]
          dbr = Glyphs.chars(Glyphs::SeqRole::BorderElbowBR, tier)[ci]
        end
      end
      {t: top_char || dt, b: bottom_char || db,
       l: left_char || dl, r: right_char || dr,
       tl: top_left_char || dtl, tr: top_right_char || dtr,
       bl: bottom_left_char || dbl, br: bottom_right_char || dbr}
    end

    def initialize(
      @left = @left,
      @top = @top,
      @right = @right,
      @bottom = @bottom,
      @opacity = @opacity,
      @horizontal_char = @horizontal_char,
      @vertical_char = @vertical_char,
      @diagonal_char = @diagonal_char,
      ratio : (Float64 | Symbol)? = nil,
    )
      case ratio
      in Float64 then self.ratio = ratio
      in Symbol  then self.ratio = ratio
      in Nil
      end
    end

    # Coerces *value* into a `Shadow`.
    def self.from(value)
      case value
      in true
        Shadow.new
      in nil, false
        Shadow.default
      in Shadow
        value
      in Side, Symbol
        # A side, either as a `Side` member (`Side::Right`, `Side::Horizontal`,
        # ...) or as one of the symbol aliases (`:right`, `:horizontal`, ...),
        # turns the named side(s) on at their default extent. Unlike the `Int`
        # arm below this is the *boolean* form — the resolved amounts only say
        # which sides are on, and each on side takes its default extent.
        s = SidedGeometry.sides value
        Shadow.new s[:left] > 0, s[:top] > 0, s[:right] > 0, s[:bottom] > 0
      in Float
        Shadow.new value
      in Int
        # A bare integer sets every side to that width, opacity staying at its
        # default — consistent with `Border`/`Padding`/`Margin`.
        v = value.to_i32
        Shadow.new(v, v, v, v)
      end
    end

    def initialize(@opacity : Float64)
    end

    # Resolves a per-side shadow spec to a width/height: `true` means the
    # side's default extent (*on*), `false`/`nil` means none, and an explicit
    # `Int` is used verbatim.
    private def dim(value : Bool | Int32?, on : Int32) : Int32
      case value
      in true       then on
      in false, nil then 0
      in Int        then value
      end
    end

    # *opacity* is keyword-only: a positional 5th argument here would be
    # ambiguous with the all-defaulted ivar initializer above (both accept
    # `(Int32, Int32, Int32, Int32, Float64)` positionally), so a caller
    # wanting a non-default opacity through this `Bool | Int32?` overload must
    # name it explicitly.
    def initialize(left : Bool | Int32?, top : Bool | Int32?, right : Bool | Int32?, bottom : Bool | Int32?, *, @opacity = @opacity, ratio : (Float64 | Symbol)? = nil)
      @left = dim left, 2
      @top = dim top, 1
      @right = dim right, 2
      @bottom = dim bottom, 1
      case ratio
      in Float64 then self.ratio = ratio
      in Symbol  then self.ratio = ratio
      in Nil
      end
    end
  end
end
