module Crysterm
  # Type of border to draw.
  enum BorderType
    Bg      # Bg color (a fill character)
    Line    # Solid line, drawn in light box-drawing chars
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

    # Whether this is a line-drawing border, as opposed to the `Bg`
    # fill-character one. Every line family uses box-drawing glyphs; only their
    # glyph set differs.
    def line_family?
      self != Bg
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
      else # Line (and any non-line type, defensively)
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

    # Whether every named instance variable is `nil`. Keeps the hand-maintained
    # `nil?` chain from drifting out of sync with the field set.
    private macro all_nil?(*fields)
      ({% for f, i in fields %}{% if i > 0 %} && {% end %}@{{ f.id }}.nil?{% end %})
    end

    property type = BorderType::Line

    # Border colors, as a `0xRRGGBB` int (`-1` = terminal default, `nil` =
    # unset). Setters come from `Colorizable` and also accept
    # `"#rrggbb"`/named strings.
    getter bg : Int32?
    getter fg : Int32?

    # Optional per-side foreground colors, letting CSS `border-top-color`,
    # `border-left-color`, ... differ per edge. Unset, a side falls back to the
    # whole-border `#fg`.
    property fg_top : Int32?
    property fg_right : Int32?
    property fg_bottom : Int32?
    property fg_left : Int32?

    # The effective foreground color for each side (per-side override or `#fg`).
    def top_fg : Int32?
      @fg_top || @fg
    end

    # :ditto:
    def right_fg : Int32?
      @fg_right || @fg
    end

    # :ditto:
    def bottom_fg : Int32?
      @fg_bottom || @fg
    end

    # :ditto:
    def left_fg : Int32?
      @fg_left || @fg
    end

    # Character used to draw a `BorderType::Bg` border. Acts as the fallback for
    # the three position-specific chars below.
    property fill_char = ' '

    # Position-specific character overrides, honored by **every** border type.
    # Unset (`nil`), each position falls back to its group (`char_corner` for the
    # four corners), then to the border's normal glyph source — the `BorderType`
    # family from the `Glyphs` registry for a line border, `fill_char` for a `Bg`
    # border. CSS spellings: `border-chars` (tl tr bl br h v) and the
    # per-position longhands (`border-top-left-char: "╭"`).
    #
    # The horizontal/vertical/corner split exists because terminal cells have a
    # ~1x2 (width:height) aspect ratio, so one char along a horizontal run reads
    # "doubly wide" versus the same char stacked vertically.
    property char_horizontal : Char? = nil
    property char_vertical : Char? = nil
    property char_corner : Char? = nil

    # Per-corner overrides; each falls back to the `char_corner` group.
    property char_top_left : Char? = nil
    property char_top_right : Char? = nil
    property char_bottom_left : Char? = nil
    property char_bottom_right : Char? = nil

    # Char to draw on the top/bottom (horizontal) sides of a `Bg` border.
    # Falls back to `fill_char`.
    def horizontal_char : Char
      @char_horizontal || @fill_char
    end

    # Char to draw on the left/right (vertical) sides of a `Bg` border.
    # Falls back to `fill_char`.
    def vertical_char : Char
      @char_vertical || @fill_char
    end

    # Char to draw where horizontal and vertical sides join (the corners /
    # "diagonal" cells) of a `Bg` border. Falls back to `fill_char`.
    def corner_char : Char
      @char_corner || @fill_char
    end

    # Per-corner chars for a `Bg` border: position override → corner group →
    # `fill_char`. A line border resolves the same overrides against its glyph
    # family instead.
    def top_left_char : Char
      @char_top_left || corner_char
    end

    # :ditto:
    def top_right_char : Char
      @char_top_right || corner_char
    end

    # :ditto:
    def bottom_left_char : Char
      @char_bottom_left || corner_char
    end

    # :ditto:
    def bottom_right_char : Char
      @char_bottom_right || corner_char
    end

    # Whether any position/group char override is set — lets the renderer skip
    # the override merge entirely for the common untouched border.
    def chars? : Bool
      !all_nil?(char_horizontal, char_vertical, char_corner,
        char_top_left, char_top_right, char_bottom_left, char_bottom_right)
    end

    # The six glyphs of a line-family border with this border's char overrides
    # merged in: each position takes its override (corners falling back to the
    # `char_corner` group), else the `BorderType` family glyph at *tier*.
    # The no-override fast path returns the family tuple untouched.
    def line_glyphs_with_overrides(tier : Glyphs::Tier)
      g = @type.line_glyphs(tier)
      return g unless chars?
      {tl: @char_top_left || @char_corner || g[:tl],
       tr: @char_top_right || @char_corner || g[:tr],
       bl: @char_bottom_left || @char_corner || g[:bl],
       br: @char_bottom_right || @char_corner || g[:br],
       h:  @char_horizontal || g[:h],
       v:  @char_vertical || g[:v]}
    end

    # Assigns the per-position corner override for a CSS longhand, keyed by
    # position symbol. Unknown positions are ignored.
    def set_char(position : Symbol, value : Char?) : Nil
      case position
      when :top_left     then @char_top_left = value
      when :top_right    then @char_top_right = value
      when :bottom_left  then @char_bottom_left = value
      when :bottom_right then @char_bottom_right = value
      when :horizontal   then @char_horizontal = value
      when :vertical     then @char_vertical = value
      when :corner       then @char_corner = value
      end
    end

    # The SGR text attributes must live on `Border` itself, rather than being
    # delegated to a `Style`, so that `sattr()` can work directly on a `Border`.
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

    # Sets one side's width, keyed by side *symbol*. Unknown sides are ignored.
    def set_width(side : Symbol, value : Int32) : Nil
      case side
      when :top    then @top = value
      when :right  then @right = value
      when :bottom then @bottom = value
      when :left   then @left = value
      end
    end

    # Sets one side's `fg_<side>` override slot, not the whole-border `#fg`.
    # Unknown sides are ignored.
    def set_color(side : Symbol, value : Int32?) : Nil
      case side
      when :top    then @fg_top = value
      when :right  then @fg_right = value
      when :bottom then @fg_bottom = value
      when :left   then @fg_left = value
      end
    end

    # Current width of one side, keyed by side symbol.
    def width_of(side : Symbol) : Int32
      case side
      when :top   then @top
      when :right then @right
      when :left  then @left
      else             @bottom
      end
    end
  end
end
