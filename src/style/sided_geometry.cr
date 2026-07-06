module Crysterm
  # Mixin providing the per-side (left/top/right/bottom) helpers shared by
  # `Border`, `Padding` and `Shadow`. Each including class declares its own
  # `left`/`top`/`right`/`bottom` properties (the defaults differ); this module
  # supplies the logic that operates on them.
  module SidedGeometry
    # Resolves a side *symbol* into per-side `{left, top, right, bottom}`
    # amounts, for the `.from` convenience constructors of `Margin`/`Padding`/
    # `Border`. Lets a single side be set declaratively — e.g.
    # `Style.new(margin: :right)` expands to a 1-cell right margin
    # (`Margin.new 0, 0, 1, 0`). All three constructors take the
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

    # The `in Symbol` arm shared verbatim by the integer `.from` constructors
    # (`Padding`/`Margin` via `zero_box`, and `Border`): resolves a side symbol
    # into per-side amounts (`SidedGeometry.sides`) and splats them into the
    # enclosing type's four-positional integer constructor. `new` binds to the
    # type at the expansion site, so each `.from` builds its own type. (`Shadow`
    # takes a `Bool` per side rather than a width, so it keeps its own arm.)
    macro new_from_symbol(value)
      %s = SidedGeometry.sides {{value}}
      new %s[:left], %s[:top], %s[:right], %s[:bottom]
    end

    # Generates the per-side integer properties plus the all-sides and
    # four-positional integer constructors shared verbatim by every
    # sided-geometry box (`Padding`, `Margin` via `zero_box`, and `Border`). The
    # only thing that differs between them is *default*, each side's resting
    # width: 0 for the zero-defaulting `Padding`/`Margin`, 1 for `Border`.
    # Just the four per-side integer properties, each with its own resting
    # default. `sided_properties` uses this with one shared *default*; `Shadow`
    # uses it directly for its asymmetric resting defaults (a right/bottom drop
    # shadow: `right: 2, bottom: 1`).
    macro sided_int_properties(left = 0, top = 0, right = 0, bottom = 0)
      property left : Int32 = {{left}}
      property top : Int32 = {{top}}
      property right : Int32 = {{right}}
      property bottom : Int32 = {{bottom}}
    end

    macro sided_properties(default = 0)
      SidedGeometry.sided_int_properties {{default}}, {{default}}, {{default}}, {{default}}

      def initialize(all : Int)
        @left = @top = @right = @bottom = all
      end

      def initialize(@left : Int, @top : Int, @right : Int, @bottom : Int)
      end
    end

    # Generates the surface shared verbatim by the zero-defaulting integer
    # sided-geometry classes (`Padding` and `Margin`): the four per-side
    # properties and integer constructors (via `sided_properties`), the
    # `.default` factory, and the `.from` value coercion.
    #
    # `.default` deliberately returns a *fresh* instance, not a shared
    # singleton: boxes are mutated in place by the per-side longhands
    # (`padding-left` etc., see `CSS::Properties#apply`) and by `Style`'s default
    # getter, so a shared object would let one widget's edit leak into every
    # other style.
    macro zero_box
      # A fresh zero box (all sides 0); never a shared singleton, see
      # `SidedGeometry.zero_box`.
      def self.default : self
        new 0
      end

      SidedGeometry.sided_properties

      def self.from(value)
        case value
        in true
          new 1
        in nil, false
          default
        in {{@type}}
          value
        in Symbol
          # One cell on the named side(s); see `SidedGeometry.new_from_symbol`.
          SidedGeometry.new_from_symbol value
        in Int
          new value, value, value, value
        end
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

    # Insets (`sign = 1`, the default) or outsets (`sign = -1`) the given position
    # rectangle by the per-side amounts. `sign = 1` moves each edge *inward*
    # (`xi`/`yi` up, `xl`/`yl` down), **shrinking** the rectangle — e.g. carving
    # the border/padding out of the outer box to get the interior; `sign = -1`
    # moves each edge outward, **growing** it back. (See the call sites in
    # `widget_rendering.cr`, whose own comment notes `adjust(pos)` "shrinks in place".)
    def adjust(pos, sign = 1)
      pos.xi += sign * @left
      pos.xl -= sign * @right
      pos.yi += sign * @top
      pos.yl -= sign * @bottom
      pos
    end

    # By-value counterpart of `#adjust` for callers holding the rectangle as
    # loose `xi/xl/yi/yl` locals: returns the grown/shrunk coordinates as a
    # tuple for one-step reassignment (`xi, xl, yi, yl = border.adjust xi, xl, yi, yl`).
    # `Tuple` is a value type, so this allocates nothing.
    def adjust(xi : Int32, xl : Int32, yi : Int32, yl : Int32, sign = 1)
      {xi + sign * @left, xl - sign * @right, yi + sign * @top, yl - sign * @bottom}
    end
  end
end
