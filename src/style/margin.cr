module Crysterm
  # Class for margin definition.
  #
  # NOTE "Margin" as in spacing *outside* the element — the mirror of `Padding`.
  # Where `Padding`/`Border` are inner insets (they shrink the *content* area and
  # push children inward, via `Widget#ileft` & co.), a margin is the element's own
  # *outer* spacing: it shifts the element inward from its computed position and
  # shrinks it within its allotted slot, without affecting the inner content
  # offsets. Same per-side order as in HTML (ltrb).
  class Margin
    include SidedGeometry

    class_property default = new 0

    property left : Int32 = 0
    property top : Int32 = 0
    property right : Int32 = 0
    property bottom : Int32 = 0

    def self.from(value)
      case value
      in true
        Margin.new 1
      in nil, false
        Margin.default
      in Margin
        value
      in Int
        Margin.new value, value, value, value
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
