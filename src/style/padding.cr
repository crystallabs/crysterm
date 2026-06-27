module Crysterm
  # Class for padding definition.
  #
  # NOTE "Padding" as in spacing around elements. Same order as in HTML (ltrb)
  class Padding
    include SidedGeometry

    # A fresh zero-padding instance. Deliberately *not* a shared singleton: a
    # `Padding` is mutated in place by the per-side longhands (`padding-left`
    # etc., see `CSS::Properties#apply`) and by `Style`'s default getter, so a
    # single shared object would let one widget's edit leak into every other
    # style (and corrupt the "no padding" baseline). Each call returns its own.
    def self.default : Padding
      new 0
    end

    property left : Int32 = 0
    property top : Int32 = 0
    property right : Int32 = 0
    property bottom : Int32 = 0

    def self.from(value)
      case value
      in true
        Padding.new 1
      in nil, false
        Padding.default
      in Padding
        value
      in Symbol
        # A side symbol (`:right`, `:horizontal`, ...) — one cell on the
        # named side(s); see `SidedGeometry.sides`.
        s = SidedGeometry.sides value
        Padding.new s[:left], s[:top], s[:right], s[:bottom]
      in Int
        Padding.new value, value, value, value
      end
    end

    def initialize(all : Int)
      @left = @top = @right = @bottom = all
    end

    def initialize(@left : Int, @top : Int, @right : Int, @bottom : Int)
    end

    # Per-side predicates, `any?` and `adjust` come from `SidedGeometry`.
  end
end
