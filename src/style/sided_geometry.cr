module Crysterm
  # Per-side (left/top/right/bottom) helpers shared by `Border`, `Padding` and
  # `Shadow`. Each including class declares its own `left`/`top`/`right`/`bottom`
  # properties, since the defaults differ; this module supplies the logic that
  # operates on them.
  module SidedGeometry
    # Resolves a *side* into per-side `{left, top, right, bottom}` amounts,
    # e.g. `SidedGeometry.sides(Side::Right)` for a 1-cell right margin. The
    # named tuple is in the `(left, top, right, bottom)` positional order the
    # box constructors take, so it can be splatted straight in.
    #
    # Recognized members (each side defaults to a 1-cell *amount*):
    #   Left Top Right Bottom  — a single side
    #   Horizontal              — left and right
    #   Vertical                — top and bottom
    #   All                     — all four (same as `true`)
    def self.sides(side : Side, amount = 1)
      l = t = r = b = 0
      case side
      in .left?       then l = amount
      in .top?        then t = amount
      in .right?      then r = amount
      in .bottom?     then b = amount
      in .horizontal? then l = r = amount
      in .vertical?   then t = b = amount
      in .all?        then l = t = r = b = amount
      end
      {left: l, top: t, right: r, bottom: b}
    end

    # `Symbol` overload, kept for callers reached through an untyped union
    # where Crystal's symbol-literal-to-enum autocast can't help (e.g.
    # `Style.new(margin: :right)`, whose `value` parameter is untyped so it can
    # accept `Border`/`Int`/`Bool`/... too). Delegates to the `Side` overload
    # once the symbol is resolved; `:x`/`:y`/`:none` are extra aliases with no
    # `Side` member of their own.
    #
    # Recognized symbols (each side defaults to a 1-cell *amount*):
    #   :left :top :right :bottom    — a single side
    #   :horizontal / :x             — left and right
    #   :vertical / :y               — top and bottom
    #   :all                         — all four (same as `true`)
    #   :none                        — none (all zero)
    def self.sides(symbol : Symbol, amount = 1)
      case symbol
      when :none
        {left: 0, top: 0, right: 0, bottom: 0}
      when :x
        sides Side::Horizontal, amount
      when :y
        sides Side::Vertical, amount
      else
        side = Side.parse?(symbol.to_s)
        raise ArgumentError.new "Unknown side symbol #{symbol.inspect} " \
                                "(expected :left/:top/:right/:bottom/" \
                                ":horizontal/:vertical/:all/:none)" unless side
        sides side, amount
      end
    end

    # The `in Side, Symbol` arm of the integer `.from` constructors: resolves a
    # side *spec* — either a `Side` member or one of the symbol aliases — into
    # per-side amounts and splats them into the enclosing type's
    # four-positional integer constructor. `new` binds to the type at the
    # expansion site, so each `.from` builds its own type.
    #
    # Both forms take the same path: `SidedGeometry.sides` has a `Side` and a
    # `Symbol` overload, so a `Side | Symbol` value resolves by union dispatch
    # and one arm can serve both.
    macro new_from_side(value)
      %s = SidedGeometry.sides {{ value }}
      new %s[:left], %s[:top], %s[:right], %s[:bottom]
    end

    # The four per-side integer properties, each with its own resting default.
    macro sided_int_properties(left = 0, top = 0, right = 0, bottom = 0)
      property left : Int32 = {{ left }}
      property top : Int32 = {{ top }}
      property right : Int32 = {{ right }}
      property bottom : Int32 = {{ bottom }}
    end

    # The four per-side integer properties at one shared resting *default*, plus
    # the all-sides and four-positional integer constructors.
    macro sided_properties(default = 0)
      SidedGeometry.sided_int_properties {{ default }}, {{ default }}, {{ default }}, {{ default }}

      def initialize(all : Int)
        @left = @top = @right = @bottom = all
      end

      # Positional order is LTRB — but two side orders exist in the wild (CSS
      # shorthands are TRBL/VH), so outside callers must name the order via
      # `.ltrb`/`.trbl`/`.vh`/the per-side constructors, or use `.from`.
      protected def initialize(@left : Int, @top : Int, @right : Int, @bottom : Int)
      end

      SidedGeometry.named_constructors
    end

    # Named constructors spelling out the side order (or the side itself) at
    # the call site — the public alternative to the protected positional
    # 4-`Int` constructor, whose bare argument order is ambiguous against
    # CSS's TRBL.
    #
    # *h* and *v* are the resting extent of one side on each axis — what the
    # zero-argument per-side constructors place. Both are a cell for the boxes
    # that measure in cells (`Padding`, `Margin`, `Border`); `Shadow`, whose
    # bands are read as a distance rather than counted, passes its own asymmetric
    # pair (a cell is about twice as tall as it is wide, so its left/right bands
    # are 2 cells against the top/bottom 1).
    macro named_constructors(h = 1, v = 1)
      # LTRB (left, top, right, bottom) order.
      def self.ltrb(left : Int, top : Int, right : Int, bottom : Int) : self
        new left.to_i32, top.to_i32, right.to_i32, bottom.to_i32
      end

      # TRBL — CSS's clockwise-from-top 4-value shorthand order.
      def self.trbl(top : Int, right : Int, bottom : Int, left : Int) : self
        ltrb left, top, right, bottom
      end

      # VH — CSS's 2-value shorthand order: *v* for top/bottom, *h* for
      # left/right.
      def self.vh(v : Int, h : Int) : self
        ltrb h, v, h, v
      end

      # Per-side constructors: *amount* on the named side(s), 0 elsewhere.
      # *amount* defaults to that axis's resting extent.
      {% for side in %w[left top right bottom horizontal vertical] %}
        {% amount = %w[top bottom vertical].includes?(side) ? v : h %}
        def self.{{ side.id }}(amount : Int = {{ amount }}) : self
          %s = SidedGeometry.sides Side::{{ side.camelcase.id }}, amount
          ltrb %s[:left], %s[:top], %s[:right], %s[:bottom]
        end
      {% end %}

      # All four sides on. *amount* applies to every side; given none, each
      # axis takes its own resting extent.
      def self.all(amount : Int? = nil) : self
        ltrb amount || {{ h }}, amount || {{ v }}, amount || {{ h }}, amount || {{ v }}
      end
    end

    # The CSS tuple-shorthand arms of a box `.from`: `{v, h}` (2-value) and
    # `{t, r, b, l}` (4-value, clockwise from top).
    macro from_tuple_arms(value)
      case {{ value }}
      in Tuple(Int32, Int32)
        vh {{ value }}[0], {{ value }}[1]
      in Tuple(Int32, Int32, Int32, Int32)
        trbl {{ value }}[0], {{ value }}[1], {{ value }}[2], {{ value }}[3]
      end
    end

    # The full surface of a zero-defaulting integer box (`Padding`, `Margin`):
    # the per-side properties and integer constructors, `.default`, and `.from`.
    macro zero_box
      # A fresh zero box (all sides 0). Must never be a shared singleton: boxes
      # are mutated in place by the per-side CSS longhands (`padding-left`, ...),
      # so one widget's edit would leak into every other style.
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
        in {{ @type }}
          value
        in Side, Symbol
          # One cell on the named side(s).
          SidedGeometry.new_from_side value
        in Int
          new value, value, value, value
        in Tuple(Int32, Int32)
          # CSS 2-value shorthand `{vertical, horizontal}`: top/bottom then
          # left/right. Constructor order is LTRB.
          new value[1], value[0], value[1], value[0]
        in Tuple(Int32, Int32, Int32, Int32)
          # CSS 4-value shorthand `{top, right, bottom, left}` (TRBL, clockwise
          # from top). Constructor order is LTRB.
          new value[3], value[0], value[1], value[2]
        end
      end
    end

    # Whether every named instance variable is `nil`. Keeps a hand-maintained
    # `nil?` chain (`Border#chars?`, `Shadow#glyphs?`) from drifting out of sync
    # with the field set. Invoked as `SidedGeometry.all_nil?(a, b, ...)` from
    # inside an includer's method body; each bare name expands to that
    # includer's `@name` ivar.
    macro all_nil?(*fields)
      ({% for f, i in fields %}{% if i > 0 %} && {% end %}@{{ f.id }}.nil?{% end %})
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

    # Is there any [amount] defined on any side? Tests each side individually
    # rather than summing them, so legitimate negative amounts (e.g. CSS
    # `margin-top: -1`) aren't masked by an unrelated side canceling the sum
    # out to zero or below.
    def any?
      @left != 0 || @top != 0 || @right != 0 || @bottom != 0
    end

    # Insets (`sign = 1`, the default) or outsets (`sign = -1`) *pos* by the
    # per-side amounts, mutating it in place. `sign = 1` moves each edge inward,
    # shrinking the rectangle — e.g. carving the border/padding out of the outer
    # box to get the interior; `sign = -1` grows it back.
    def adjust(pos, sign = 1)
      pos.xi += sign * @left
      pos.xl -= sign * @right
      pos.yi += sign * @top
      pos.yl -= sign * @bottom
      pos
    end

    # By-value counterpart of `#adjust`, for callers holding the rectangle as
    # loose `xi/xl/yi/yl` locals. Returns a `Tuple`, a value type, so this
    # allocates nothing.
    def adjust(xi : Int32, xl : Int32, yi : Int32, yl : Int32, sign = 1)
      {xi + sign * @left, xl - sign * @right, yi + sign * @top, yl - sign * @bottom}
    end

    # *r* shrunk inward by these per-side amounts — the by-value, `Rectangle`-
    # returning counterpart of `#adjust(sign: 1)` that hides its opaque sign
    # flag. Qt's `QRect::marginsRemoved(QMargins)`; backs `Rectangle#-`.
    def inset(r : Rectangle) : Rectangle
      xi, xl, yi, yl = adjust r.xi, r.xl, r.yi, r.yl, 1
      Rectangle.of_edges xi, yi, xl, yl
    end

    # *r* grown outward by these per-side amounts — the by-value counterpart of
    # `#adjust(sign: -1)`. Qt's `QRect::marginsAdded(QMargins)`; backs
    # `Rectangle#+`.
    def outset(r : Rectangle) : Rectangle
      xi, xl, yi, yl = adjust r.xi, r.xl, r.yi, r.yl, -1
      Rectangle.of_edges xi, yi, xl, yl
    end
  end
end
