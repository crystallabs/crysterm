module Crysterm
  class Screen
    # Screen rows and cells

    # Individual screen cell
    class Cell
      include Comparable(self)

      property attr : Int32 = Screen::DEFAULT_ATTR

      property char : Char = Screen::DEFAULT_CHAR

      def initialize(@attr, @char)
      end

      def initialize(@char)
      end

      def initialize
      end

      def <=>(other : Cell)
        if (d = @attr <=> other.attr) == 0
          @char <=> other.char
        else
          d
        end
      end

      def <=>(other : Tuple(Int32, Char))
        if (d = @attr <=> other[0]) == 0
          @char <=> other[1]
        else
          d
        end
      end
    end

    # Individual screen row: a list of `Cell`s plus a `dirty` flag.
    #
    # This used to subclass `Array(Cell)`. Subclassing a stdlib generic is
    # deprecated, and—more importantly—it promotes every `Array(Cell)` in the
    # whole program (including in unrelated shards) to the virtual type
    # `Array(Cell)+`, which produces confusing compile errors far away from here
    # (same class of problem as issue #30). It now *wraps* an array and forwards
    # the array API (`push`, `pop`, `[]`, `[]=`, `size`, `each`, ...) to it via
    # `forward_missing_to`, so no `Array(Cell)` is ever subclassed.
    class Row
      property dirty = false

      # Backing store of cells.
      getter cells : Array(Cell)

      def initialize
        @cells = Array(Cell).new
      end

      # `width` is used only as the initial capacity (matching the old
      # `super width`); `cell` is accepted for call compatibility but, as
      # before, the cells are populated separately (see `Screen#adjust_width`).
      def initialize(width : Int, cell : Cell | Tuple(Int32, Char)? = nil)
        @cells = Array(Cell).new(width)
      end

      forward_missing_to @cells
    end
    # end
  end
end
