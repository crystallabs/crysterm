module Crysterm
  # A widget's drop shadow.
  class Shadow
    include SidedGeometry

    # Whether every named instance variable is `nil`. Keeps the hand-maintained
    # `nil?` chain from drifting out of sync with the field set.
    private macro all_nil?(*fields)
      ({% for f, i in fields %}{% if i > 0 %} && {% end %}@{{ f.id }}.nil?{% end %})
    end

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

    # Shadow alpha value (0 == full transparency, 1 == full opacity)
    property alpha : Float64 = 0.5

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

    # Whether any half-block glyph is configured (any group, side or corner).
    # When false the shadow is a plain full-cell alpha blend, which the renderer
    # paints on a faster, undivided path.
    def glyphs? : Bool
      !all_nil?(horizontal_char, vertical_char, diagonal_char,
        top_char, bottom_char, left_char, right_char,
        top_left_char, top_right_char, bottom_left_char, bottom_right_char)
    end

    def initialize(
      @left = @left,
      @top = @top,
      @right = @right,
      @bottom = @bottom,
      @alpha = @alpha,
      @horizontal_char = @horizontal_char,
      @vertical_char = @vertical_char,
      @diagonal_char = @diagonal_char,
    )
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
      in Side
        # A side (`Side::Right`, `Side::Horizontal`, ...) turns the named
        # side(s) on at their default extent.
        s = SidedGeometry.sides value
        Shadow.new s[:left] > 0, s[:top] > 0, s[:right] > 0, s[:bottom] > 0
      in Symbol
        # A side symbol (`:right`, `:horizontal`, ...) turns the named side(s)
        # on at their default extent.
        s = SidedGeometry.sides value
        Shadow.new s[:left] > 0, s[:top] > 0, s[:right] > 0, s[:bottom] > 0
      in Float
        Shadow.new value
      in Int
        # A bare integer sets every side to that width, alpha staying at its
        # default — consistent with `Border`/`Padding`/`Margin`.
        v = value.to_i32
        Shadow.new(v, v, v, v)
      end
    end

    def initialize(@alpha : Float64)
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

    def initialize(left : Bool | Int32?, top : Bool | Int32?, right : Bool | Int32?, bottom : Bool | Int32?, @alpha = @alpha)
      @left = dim left, 2
      @top = dim top, 1
      @right = dim right, 2
      @bottom = dim bottom, 1
    end
  end
end
