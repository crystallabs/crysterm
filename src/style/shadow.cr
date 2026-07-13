module Crysterm
  # Class for shadow definition.
  class Shadow
    include SidedGeometry

    # Whether every one of the named instance-variable fields is `nil` — the
    # all-unset fast-path test for `#glyphs?`. Mirrors `Border`'s private copy
    # (a macro can't be shared across the two files/types by scope).
    private macro all_nil?(*fields)
      ({% for f, i in fields %}{% if i > 0 %} && {% end %}@{{ f.id }}.nil?{% end %})
    end

    # Fresh zero-shadow instance ("no shadow": all sides 0). Not a shared
    # singleton (like `Padding.default`/`Margin.default`): `Shadow` is mutable,
    # and `Style`'s default getter hands one to every `Style` — a shared
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

    # Optional glyphs used to paint a *thin* shadow. When a band's glyph is set,
    # that band is drawn with the half-block character instead of darkening the
    # whole cell — so the shadow occupies only part of a cell and escapes the
    # terminal's ~2:1 cell aspect ratio. `nil` (the default for every field)
    # keeps the classic full-cell alpha-blended shadow.
    #
    # The shadow tone is the cell *background* (a gap-free solid fill), and the
    # glyph's foreground carries the untouched backdrop over the other half —
    # so choose the glyph whose *solid* half faces away from the widget: `▄`
    # shadows the top half (a bottom-edge shadow that hugs the widget), `▀` the
    # bottom, `▐` the left half (a right-edge shadow), `▌` the right.
    #
    # There are eight independently selectable glyphs — the four sides and the
    # four diagonal (corner) cells where two sides meet — resolved through group
    # fallbacks so you set only what differs:
    #
    # * side runs fall back per axis to `horizontal_char` (top/bottom) and
    #   `vertical_char` (left/right);
    # * the corner cells fall back to `diagonal_char`, then to `horizontal_char`
    #   (the glyph running along the merge line).
    #
    # Split this finely because a cell's height and width differ, so each run and
    # corner may need its own half-block to read as equally thin.
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
    # When false the shadow is a plain full-cell alpha blend and the renderer
    # takes its faster, undivided path.
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

    # Parse shadow value
    def self.from(value)
      case value
      in true
        Shadow.new
      in nil, false
        Shadow.default
      in Shadow
        value
      in Symbol
        # A side symbol (`:right`, `:horizontal`, ...) turns the named side(s)
        # on at their default extent (see `Bool` constructor, `SidedGeometry.sides`).
        s = SidedGeometry.sides value
        Shadow.new s[:left] > 0, s[:top] > 0, s[:right] > 0, s[:bottom] > 0
      in Float
        Shadow.new value
      in Int
        # Consistent with `Border`/`Padding`/`Margin` `.from`: a bare integer sets
        # every side to that width (alpha stays at its default). Sides are `Int32`.
        v = value.to_i32
        Shadow.new(v, v, v, v)
      end
    end

    # def initialize(all : Int)
    #  @left = @top = @right = @bottom = all
    # end

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

    # Per-side predicates and `any?` come from `SidedGeometry`.
  end
end
