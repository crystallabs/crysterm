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
      when :none # leave all at 0 (l/t/r/b stay 0)
      else
        raise ArgumentError.new "Unknown side symbol #{symbol.inspect} " \
                                "(expected :left/:top/:right/:bottom/" \
                                ":horizontal/:vertical/:all/:none)"
      end
      {left: l, top: t, right: r, bottom: b}
    end

    # Generates the surface shared verbatim by the zero-defaulting integer
    # sided-geometry classes (`Padding` and `Margin`), which are otherwise
    # identical: the four per-side properties (each defaulting to 0), the
    # `.default` factory, the `.from` value coercion, and the `all` /
    # four-positional integer constructors. Mix it in with
    # `SidedGeometry.zero_box` from the class body.
    #
    # `.default` deliberately returns a *fresh* instance rather than a shared
    # singleton: each box is mutated in place by the per-side longhands
    # (`padding-left` etc., see `CSS::Properties#apply`) and by `Style`'s default
    # getter, so a single shared object would let one widget's edit leak into
    # every other style (and corrupt the "no padding"/"no margin" baseline).
    macro zero_box
      # A fresh zero box (all sides 0); never a shared singleton, see
      # `SidedGeometry.zero_box`.
      def self.default : self
        new 0
      end

      property left : Int32 = 0
      property top : Int32 = 0
      property right : Int32 = 0
      property bottom : Int32 = 0

      def self.from(value)
        case value
        in true
          new 1
        in nil, false
          default
        in {{@type}}
          value
        in Symbol
          # A side symbol (`:right`, `:horizontal`, ...) — one cell on the
          # named side(s); see `SidedGeometry.sides`.
          s = SidedGeometry.sides value
          new s[:left], s[:top], s[:right], s[:bottom]
        in Int
          new value, value, value, value
        end
      end

      def initialize(all : Int)
        @left = @top = @right = @bottom = all
      end

      def initialize(@left : Int, @top : Int, @right : Int, @bottom : Int)
      end
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

    # By-value counterpart of `#adjust` for callers that hold the rectangle as
    # loose `xi/xl/yi/yl` locals rather than a position object: returns the
    # grown (`sign = 1`) / shrunk (`sign = -1`) coordinates as a tuple, so they
    # can be reassigned in one step (`xi, xl, yi, yl = border.adjust xi, xl, yi, yl`).
    # The arithmetic is identical to the object form; `Tuple` is a value type so
    # this allocates nothing.
    def adjust(xi : Int32, xl : Int32, yi : Int32, yl : Int32, sign = 1)
      {xi + sign * @left, xl - sign * @right, yi + sign * @top, yl - sign * @bottom}
    end
  end
end
