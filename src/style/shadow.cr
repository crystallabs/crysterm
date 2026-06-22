module Crysterm
  # Class for shadow definition.
  class Shadow
    include SidedGeometry

    class_property default = new 0, 0, 0, 0

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
