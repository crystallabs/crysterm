module Crysterm
  # Class for shadow definition.
  class Shadow
    include SidedGeometry

    # A fresh zero-shadow instance ("no shadow": all sides 0). Deliberately *not*
    # a shared singleton — exactly like `Padding.default`/`Margin.default`: a
    # `Shadow` is mutable through its per-side/alpha setters (`left`/`top`/
    # `right`/`bottom`/`alpha`), and `Style`'s default getter (`getter shadow =
    # Shadow.default`) hands one to *every* `Style`. A single shared object would
    # let one style's in-place edit leak into every other style (and corrupt the
    # "no shadow" baseline). Each call returns its own.
    def self.default : Shadow
      new 0, 0, 0, 0
    end

    # Width of shadow on the left side
    property left : Int32 = 0

    # Height of shadow on the top side
    property top : Int32 = 0

    # Width of shadow on the right side
    property right : Int32 = 2

    # Height of shadow on the bottom side
    property bottom : Int32 = 1

    # Shadow alpha value (0 == full transparency, 1 == full opacity)
    property alpha : Float64 = 0.5

    def initialize(
      @left = @left,
      @top = @top,
      @right = @right,
      @bottom = @bottom,
      @alpha = @alpha,
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
        # A side symbol (`:right`, `:horizontal`, ...) — turns the named
        # side(s) *on* at their default extent (see the `Bool` constructor and
        # `SidedGeometry.sides`).
        s = SidedGeometry.sides value
        Shadow.new s[:left] > 0, s[:top] > 0, s[:right] > 0, s[:bottom] > 0
      in Float
        Shadow.new value
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
