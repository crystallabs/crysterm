module Crysterm
  # Type of border to draw.
  enum BorderType
    Bg     # Bg color (a fill character, see `Border#fill_char`)
    Line   # Solid line, drawn in light box-drawing chars
    Dashed # Dashed line (light box-drawing dashes)
    Dotted # Dotted line (light box-drawing dots)
    Double # Double line

    # DotDash
    # DotDotDash
    # Groove
    # Ridge
    # Inset
    # Outset

    # Whether this is a line-drawing border (as opposed to the `Bg`
    # fill-character border). `Line`, `Dashed`, `Dotted` and `Double` all use
    # box-drawing glyphs; only their glyph set differs.
    def line_family?
      self != Bg
    end

    # The six glyphs used to draw a line-family border: the four corners
    # (`tl`/`tr`/`bl`/`br`) plus the horizontal (`h`) and vertical (`v`) runs,
    # at support *tier* (defaults to the classic Unicode set). The dashed/
    # dotted variants keep the light corners and only swap the straight runs;
    # `Double` swaps all six; at `Tier::Ascii` every family collapses to
    # `+`/`-`/`|` (`=` runs for `Double`). Values come from the central
    # `Glyphs` registry, so `Glyphs.set` retunes borders toolkit-wide.
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
      else # Line (and any non-line type, defensively)
        {tl: Glyphs[Glyphs::Role::BorderLineTL, tier], tr: Glyphs[Glyphs::Role::BorderLineTR, tier],
         bl: Glyphs[Glyphs::Role::BorderLineBL, tier], br: Glyphs[Glyphs::Role::BorderLineBR, tier],
         h: Glyphs[Glyphs::Role::BorderLineH, tier], v: Glyphs[Glyphs::Role::BorderLineV, tier]}
      end
    end
  end

  # Class for border definition.
  class Border
    include Colorizable
    include SidedGeometry

    property type = BorderType::Line

    # Border colors. Native form is a `0xRRGGBB` int (`-1` = terminal default,
    # `nil` = unset); `"#rrggbb"`/named strings are accepted for backwards
    # compatibility and parsed via `Colors.convert`. See `Style#fg`. The setters
    # come from `Colorizable`.
    getter bg : Int32?
    getter fg : Int32?

    # Optional per-side foreground colors (`0xRRGGBB` int or `nil`). When unset,
    # the side falls back to the whole-border `#fg` (see `#top_fg` etc.). These
    # let `border-top-color`/`border-left-color`/... differ per edge.
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

    # Position-specific characters for `BorderType::Bg` borders. When unset
    # (`nil`) each falls back to `char` (see `#horizontal_char`, `#vertical_char`,
    # `#corner_char`).
    #
    # Split three ways because terminal cells have a ~1x2 (width:height)
    # aspect ratio, so one char along a horizontal run reads "doubly wide"
    # versus the same char stacked vertically. Setting
    # `char_horizontal`/`char_vertical`/`char_corner` independently keeps the
    # border uniform: e.g. `─` horizontally, `│` vertically, `┼`/`+` at joins.
    property char_horizontal : Char? = nil
    property char_vertical : Char? = nil
    property char_corner : Char? = nil

    # Char to draw on the top/bottom (horizontal) sides. Falls back to `char`.
    def horizontal_char : Char
      @char_horizontal || @fill_char
    end

    # Char to draw on the left/right (vertical) sides. Falls back to `char`.
    def vertical_char : Char
      @char_vertical || @fill_char
    end

    # Char to draw where horizontal and vertical sides join (the corners /
    # "diagonal" cells). Falls back to `char`.
    def corner_char : Char
      @char_corner || @fill_char
    end

    # SGR text-attribute booleans (bold/italic/underline/blink/reverse/strike/
    # visible) are owned by `TextAttributes`, shared with `Style`. They must
    # be present here (rather than delegating to a `Style`) for `sattr()` to be
    # able to work directly on the Border object.
    include TextAttributes

    # Per-side widths (default 1) and the all-sides / four-positional integer
    # constructors, shared with `Padding`/`Margin` but defaulting to a 1-cell box.
    SidedGeometry.sided_properties 1

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
        # named side(s); see `SidedGeometry.new_from_symbol`.
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

    # XXX enable these two after -Dpreview_overload_order becomes the default
    # def initialize(left_and_right, top_and_bottom)
    #  @left = @right = left_and_right
    #  @top = @bottom = top_and_bottom
    # end

    # def initialize(all : Bool = true)
    #  @left = @top = @right = @bottom = all
    # end

    # Per-side width/color access keyed by a side *symbol*
    # (`:top`/`:right`/`:bottom`/`:left`), so callers (`CSS::Properties`' per-side
    # border longhands/shorthands) need not repeat the four-arm dispatch. Unknown
    # side symbols are ignored. `set_color` targets the per-side
    # `fg_<side>` override slots (see `#top_fg` etc.), not the whole-border `#fg`.
    def set_width(side : Symbol, value : Int32) : Nil
      case side
      when :top    then @top = value
      when :right  then @right = value
      when :bottom then @bottom = value
      when :left   then @left = value
      end
    end

    # :ditto:
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

    # Per-side predicates (`left?`/`top?`/`right?`/`bottom?`), `any?` and
    # `adjust` come from `SidedGeometry`.
  end
end
