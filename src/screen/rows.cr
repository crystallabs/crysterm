module Crysterm
  class Screen
    module Rows
      # Individual screen cell
      class Cell
        include Comparable(self)
        # Same as @dattr
        property attr : Int32 = ((0 << 18) | (0x1ff << 9)) | 0x1ff
        property char : Char = ' '

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

      # Individual screen row
      class Row < Array(Cell)
        property dirty = false

        def initialize
          super
        end

        def initialize(width, cell : Cell | Tuple(Int32, Char) = {@attr, @char})
          super width
        end
      end
    end
  end
end
