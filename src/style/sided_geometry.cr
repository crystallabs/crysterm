module Crysterm
  # Mixin providing the per-side (left/top/right/bottom) helpers shared by
  # `Border`, `Padding` and `Shadow`. Each including class declares its own
  # `left`/`top`/`right`/`bottom` properties (the defaults differ); this module
  # supplies the logic that operates on them.
  module SidedGeometry
    # Is there anything on the left side?
    def left?
      @left > 0
    end

    # Is there anything on the top side?
    def top?
      @top > 0
    end

    # Is there anything on the right side?
    def right?
      @right > 0
    end

    # Is there anything on the bottom side?
    def bottom?
      @bottom > 0
    end

    # Is there any [amount] defined on any side?
    def any?
      (@left + @top + @right + @bottom) > 0
    end

    # Grows (`sign = 1`) or shrinks (`sign = -1`) the given position rectangle
    # by the per-side amounts.
    def adjust(pos, sign = 1)
      pos.xi += sign * @left
      pos.xl -= sign * @right
      pos.yi += sign * @top
      pos.yl -= sign * @bottom
      pos
    end
  end
end
