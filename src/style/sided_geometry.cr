module Crysterm
  # Mixin providing the per-side (left/top/right/bottom) helpers shared by
  # `Border`, `Padding` and `Shadow`. Each including class declares its own
  # `left`/`top`/`right`/`bottom` properties (the defaults differ); this module
  # supplies the logic that operates on them.
  module SidedGeometry
    # Resolves a side *symbol* into per-side `{left, top, right, bottom}`
    # amounts, for the `.from` convenience constructors of `Margin`/`Padding`/
    # `Border`. This is what lets a single side be set declaratively — e.g.
    # `Style.new(margin: :right)` expands to a 1-cell right margin
    # (`Margin.new 0, 0, 1, 0`). The constructors of all three classes take the
    # `(left, top, right, bottom)` positional order, so the returned named tuple
    # can be splatted straight in.
    #
    # Recognized symbols (each side defaults to a 1-cell *amount*):
    #   :left :top :right :bottom    — a single side
    #   :horizontal / :x             — left and right
    #   :vertical / :y               — top and bottom
    #   :all                         — all four (same as `true`)
    #   :none                        — none (all zero)
    def self.sides(symbol : Symbol, amount = 1)
      l = t = r = b = 0
      case symbol
      when :left           then l = amount
      when :top            then t = amount
      when :right          then r = amount
      when :bottom         then b = amount
      when :horizontal, :x then l = r = amount
      when :vertical, :y   then t = b = amount
      when :all            then l = t = r = b = amount
      when :none # leave all at 0
 then
      else
        raise ArgumentError.new "Unknown side symbol #{symbol.inspect} " \
                                "(expected :left/:top/:right/:bottom/" \
                                ":horizontal/:vertical/:all/:none)"
      end
      {left: l, top: t, right: r, bottom: b}
    end

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
