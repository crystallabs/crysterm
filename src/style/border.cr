module Crysterm
  # Type of border to draw.
  enum BorderType
    Fill    # Solid fill color (a fill character)
    Solid   # Solid line, drawn in light box-drawing chars
    Dashed  # Dashed line (light box-drawing dashes)
    Dotted  # Dotted line (light box-drawing dots)
    Double  # Double line
    Rounded # Solid light line with arc (rounded) corners: ╭╮╰╯

    # DotDash
    # DotDotDash
    # Groove
    # Ridge
    # Inset
    # Outset

    # Whether this is a line-drawing border, as opposed to the `Fill`
    # fill-character one. Every line family uses box-drawing glyphs; only their
    # glyph set differs.
    def line_family?
      self != Fill
    end

    # The six glyphs used to draw a line-family border at support *tier*: the
    # four corners (`tl`/`tr`/`bl`/`br`) plus the horizontal (`h`) and vertical
    # (`v`) runs. Values come from the central `Glyphs` registry, so `Glyphs.set`
    # retunes borders toolkit-wide.
    def line_glyphs(tier : Glyphs::Tier = Glyphs::Tier::Unicode)
      case self
      when Double
        {tl: Glyphs[Glyphs::Role::BorderDoubleTL, tier], tr: Glyphs[Glyphs::Role::BorderDoubleTR, tier],
         bl: Glyphs[Glyphs::Role::BorderDoubleBL, tier], br: Glyphs[Glyphs::Role::BorderDoubleBR, tier],
         h: Glyphs[Glyphs::Role::BorderDoubleH, tier], v: Glyphs[Glyphs::Role::BorderDoubleV, tier]}
      when Dashed
        {tl: Glyphs[Glyphs::Role::BorderDashedTL, tier], tr: Glyphs[Glyphs::Role::BorderDashedTR, tier],
         bl: Glyphs[Glyphs::Role::BorderDashedBL, tier], br: Glyphs[Glyphs::Role::BorderDashedBR, tier],
         h: Glyphs[Glyphs::Role::BorderDashedH, tier], v: Glyphs[Glyphs::Role::BorderDashedV, tier]}
      when Dotted
        {tl: Glyphs[Glyphs::Role::BorderDottedTL, tier], tr: Glyphs[Glyphs::Role::BorderDottedTR, tier],
         bl: Glyphs[Glyphs::Role::BorderDottedBL, tier], br: Glyphs[Glyphs::Role::BorderDottedBR, tier],
         h: Glyphs[Glyphs::Role::BorderDottedH, tier], v: Glyphs[Glyphs::Role::BorderDottedV, tier]}
      when Rounded
        {tl: Glyphs[Glyphs::Role::BorderRoundedTL, tier], tr: Glyphs[Glyphs::Role::BorderRoundedTR, tier],
         bl: Glyphs[Glyphs::Role::BorderRoundedBL, tier], br: Glyphs[Glyphs::Role::BorderRoundedBR, tier],
         h: Glyphs[Glyphs::Role::BorderRoundedH, tier], v: Glyphs[Glyphs::Role::BorderRoundedV, tier]}
      else # Solid (and any non-solid type, defensively)
        {tl: Glyphs[Glyphs::Role::BorderLineTL, tier], tr: Glyphs[Glyphs::Role::BorderLineTR, tier],
         bl: Glyphs[Glyphs::Role::BorderLineBL, tier], br: Glyphs[Glyphs::Role::BorderLineBR, tier],
         h: Glyphs[Glyphs::Role::BorderLineH, tier], v: Glyphs[Glyphs::Role::BorderLineV, tier]}
      end
    end
  end

  # A widget's border.
  class Border
    include Colorizable
    include SidedGeometry

    # Border-char override position (CSS `border-*-char` longhands / the
    # `border-chars` shorthand): the four corners plus the `horizontal`/
    # `vertical` run groups, and the `corner` group that seeds all four
    # corners at once. Distinct from `Side` — a corner override needs its own
    # axis (`top_left`, ...) that a plain side can't name.
    enum CharPosition
      TopLeft
      TopRight
      BottomLeft
      BottomRight
      Horizontal
      Vertical
      Corner
    end

    # Whether every named instance variable is `nil`. Keeps the hand-maintained
    # `nil?` chain from drifting out of sync with the field set.
    private macro all_nil?(*fields)
      ({% for f, i in fields %}{% if i > 0 %} && {% end %}@{{ f.id }}.nil?{% end %})
    end

    property type = BorderType::Solid

    # Border colors, as a `0xRRGGBB` int (`-1` = terminal default, `nil` =
    # unset). Setters come from `Colorizable` and also accept
    # `"#rrggbb"`/named strings.
    getter bg : Int32?
    getter fg : Int32?

    # Optional per-side foreground colors, letting CSS `border-top-color`,
    # `border-left-color`, ... differ per edge. Unset, a side falls back to the
    # whole-border `#fg`. Explicit setter + falling-back getter under the same
    # name (mirrors `Shadow`'s per-side char overrides), so the write and read
    # spelling agree.
    @top_fg : Int32?
    @right_fg : Int32?
    @bottom_fg : Int32?
    @left_fg : Int32?

    setter top_fg, right_fg, bottom_fg, left_fg

    # The effective foreground color for each side (per-side override or `#fg`).
    def top_fg : Int32?
      @top_fg || @fg
    end

    # :ditto:
    def right_fg : Int32?
      @right_fg || @fg
    end

    # :ditto:
    def bottom_fg : Int32?
      @bottom_fg || @fg
    end

    # :ditto:
    def left_fg : Int32?
      @left_fg || @fg
    end

    # Character used to draw a `BorderType::Fill` border. Acts as the fallback for
    # the three position-specific chars below.
    property fill_char = ' '

    # Position-specific character overrides, honored by **every** border type.
    # Unset (`nil`), each position falls back to its group (`corner_char` for the
    # four corners), then to the border's normal glyph source — the `BorderType`
    # family from the `Glyphs` registry for a line border, `fill_char` for a `Fill`
    # border. CSS spellings: `border-chars` (tl tr bl br h v) and the
    # per-position longhands (`border-top-left-char: "╭"`).
    #
    # The horizontal/vertical/corner split exists because terminal cells have a
    # ~1x2 (width:height) aspect ratio, so one char along a horizontal run reads
    # "doubly wide" versus the same char stacked vertically.
    #
    # Each position uses `Shadow`'s scheme: an explicit setter on the raw ivar,
    # plus a falling-back getter of the same name — so the write and read
    # spelling always agree (no `char_foo=` vs `foo_char` split).
    @horizontal_char : Char? = nil
    @vertical_char : Char? = nil
    @corner_char : Char? = nil

    setter horizontal_char, vertical_char, corner_char

    # Per-corner overrides; each falls back to the `corner_char` group.
    @top_left_char : Char? = nil
    @top_right_char : Char? = nil
    @bottom_left_char : Char? = nil
    @bottom_right_char : Char? = nil

    setter top_left_char, top_right_char, bottom_left_char, bottom_right_char

    # Char to draw on the top/bottom (horizontal) sides of a `Fill` border.
    # Falls back to `fill_char`.
    def horizontal_char : Char
      @horizontal_char || @fill_char
    end

    # Char to draw on the left/right (vertical) sides of a `Fill` border.
    # Falls back to `fill_char`.
    def vertical_char : Char
      @vertical_char || @fill_char
    end

    # Char to draw where horizontal and vertical sides join (the corners /
    # "diagonal" cells) of a `Fill` border. Falls back to `fill_char`.
    def corner_char : Char
      @corner_char || @fill_char
    end

    # Per-corner chars for a `Fill` border: position override → corner group →
    # `fill_char`. A line border resolves the same overrides against its glyph
    # family instead.
    def top_left_char : Char
      @top_left_char || corner_char
    end

    # :ditto:
    def top_right_char : Char
      @top_right_char || corner_char
    end

    # :ditto:
    def bottom_left_char : Char
      @bottom_left_char || corner_char
    end

    # :ditto:
    def bottom_right_char : Char
      @bottom_right_char || corner_char
    end

    # Whether any position/group char override is set — lets the renderer skip
    # the override merge entirely for the common untouched border.
    def chars? : Bool
      !all_nil?(horizontal_char, vertical_char, corner_char,
        top_left_char, top_right_char, bottom_left_char, bottom_right_char)
    end

    # The six glyphs of a line-family border with this border's char overrides
    # merged in: each position takes its override (corners falling back to the
    # `corner_char` group), else the `BorderType` family glyph at *tier*.
    # The no-override fast path returns the family tuple untouched.
    def line_glyphs_with_overrides(tier : Glyphs::Tier)
      g = @type.line_glyphs(tier)
      return g unless chars?
      {tl: @top_left_char || @corner_char || g[:tl],
       tr: @top_right_char || @corner_char || g[:tr],
       bl: @bottom_left_char || @corner_char || g[:bl],
       br: @bottom_right_char || @corner_char || g[:br],
       h:  @horizontal_char || g[:h],
       v:  @vertical_char || g[:v]}
    end

    # Assigns the per-position corner override for a CSS longhand, keyed by
    # *position*. Only called by `CSS::Properties`, so kept `protected`.
    protected def set_char(position : CharPosition, value : Char?) : Nil
      case position
      in .top_left?     then @top_left_char = value
      in .top_right?    then @top_right_char = value
      in .bottom_left?  then @bottom_left_char = value
      in .bottom_right? then @bottom_right_char = value
      in .horizontal?   then @horizontal_char = value
      in .vertical?     then @vertical_char = value
      in .corner?       then @corner_char = value
      end
    end

    # The SGR text attributes must live on `Border` itself, rather than being
    # delegated to a `Style`, so that `style_to_attr()` can work directly on a `Border`.
    include TextAttributes

    # Per-side widths and integer constructors, defaulting to a 1-cell box.
    SidedGeometry.sided_properties 1

    # Coerces *value* into a `Border`.
    def self.from(value)
      case value
      in true
        Border.new
      in nil, false
        Border.new 0
      in BorderType
        Border.new value
      in Border
        value
      in Side
        # A side (`Side::Right`, `Side::Horizontal`, ...) — one cell on the
        # named side(s).
        SidedGeometry.new_from_side value
      in Symbol
        # A side symbol (`:right`, `:horizontal`, ...) — one cell on the
        # named side(s).
        SidedGeometry.new_from_symbol value
      in Int
        Border.new value, value, value, value
      end
    end

    def initialize(
      @type = @type,
      bg = nil,
      fg = nil,
      @left = @left,
      @top = @top,
      @right = @right,
      @bottom = @bottom,
    )
      # Route through setters so a native int or a `"#rrggbb"`/named string
      # both resolve to the native int form.
      self.bg = bg unless bg.nil?
      self.fg = fg unless fg.nil?
    end

    # XXX A `(left_and_right, top_and_bottom)` pair constructor and a
    # `(all : Bool = true)` one are only addable once -Dpreview_overload_order
    # is the default.

    # Sets one side's width, keyed by *side*. Only called by
    # `CSS::Properties`, so kept `protected`. *side* must be a single
    # side (`Left`/`Top`/`Right`/`Bottom`); `Horizontal`/`Vertical`/`All` don't
    # apply to a single-side setter and raise.
    protected def set_width(side : Side, value : Int32) : Nil
      case side
      in .top?    then @top = value
      in .right?  then @right = value
      in .bottom? then @bottom = value
      in .left?   then @left = value
      in .horizontal?, .vertical?, .all?
        raise ArgumentError.new "Border#set_width expects a single side " \
                                "(Left/Top/Right/Bottom), got #{side}"
      end
    end

    # Sets one side's `<side>_fg` override slot, not the whole-border `#fg`.
    # Only called by `CSS::Properties`, so kept `protected`. *side* must
    # be a single side; `Horizontal`/`Vertical`/`All` raise (see `#set_width`).
    protected def set_color(side : Side, value : Int32?) : Nil
      case side
      in .top?    then @top_fg = value
      in .right?  then @right_fg = value
      in .bottom? then @bottom_fg = value
      in .left?   then @left_fg = value
      in .horizontal?, .vertical?, .all?
        raise ArgumentError.new "Border#set_color expects a single side " \
                                "(Left/Top/Right/Bottom), got #{side}"
      end
    end

    # Current width of one side, keyed by *side*. Only called by
    # `CSS::Properties`, so kept `protected`. *side* must be a single
    # side; `Horizontal`/`Vertical`/`All` raise (see `#set_width`).
    protected def width_of(side : Side) : Int32
      case side
      in .top?    then @top
      in .right?  then @right
      in .left?   then @left
      in .bottom? then @bottom
      in .horizontal?, .vertical?, .all?
        raise ArgumentError.new "Border#width_of expects a single side " \
                                "(Left/Top/Right/Bottom), got #{side}"
      end
    end
  end
end
