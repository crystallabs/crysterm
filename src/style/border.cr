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
    # One `when`-arm body per line-family `BorderType`, keyed by the `Glyphs::Role`
    # name family prefix (`BorderDouble*`, `BorderLine*` for `Solid`, ...): all
    # five arms build the identical `{tl:,tr:,bl:,br:,h:,v:}` tuple shape,
    # differing only by that prefix, so a macro fans it out instead of five
    # hand-written copies.
    private macro border_glyph_tuple(family)
      {tl: Glyphs[Glyphs::Role::{{ family.id }}TL, tier], tr: Glyphs[Glyphs::Role::{{ family.id }}TR, tier],
       bl: Glyphs[Glyphs::Role::{{ family.id }}BL, tier], br: Glyphs[Glyphs::Role::{{ family.id }}BR, tier],
       h: Glyphs[Glyphs::Role::{{ family.id }}H, tier], v: Glyphs[Glyphs::Role::{{ family.id }}V, tier]}
    end

    def line_glyphs(tier : Glyphs::Tier = Glyphs::Tier::Unicode)
      case self
      when Double
        border_glyph_tuple BorderDouble
      when Dashed
        border_glyph_tuple BorderDashed
      when Dotted
        border_glyph_tuple BorderDotted
      when Rounded
        border_glyph_tuple BorderRounded
      else # Solid (and any non-solid type, defensively)
        border_glyph_tuple BorderLine
      end
    end
  end

  # A widget's border.
  class Border
    include Colorizable
    include SidedGeometry

    # Border-char override position (CSS `border-*-char` longhands / the
    # `border-chars` shorthand): the four corners, the four side runs, plus the
    # `horizontal`/`vertical` run groups and the `corner` group that seed them.
    # Distinct from `Side` — a corner override needs its own axis (`top_left`,
    # ...) that a plain side can't name.
    enum CharPosition
      TopLeft
      TopRight
      BottomLeft
      BottomRight
      Top
      Right
      Bottom
      Left
      Horizontal
      Vertical
      Corner
    end

    # Raises the uniform "single side expected" `ArgumentError` for the
    # multi-side (`Horizontal`/`Vertical`/`All`) arms of the per-side
    # dispatchers below. `@def.name` names the enclosing method at expansion,
    # so the message can never drift from the method it actually fires in.
    private macro raise_multi_side(side)
      raise ArgumentError.new "Border#" + {{ @def.name.stringify }} +
        " expects a single side (Left/Top/Right/Bottom), got #{ {{ side }} }"
    end

    # Reads one side's `@<side><suffix>` ivar, keyed by *side*. *side* must be
    # a single side (`Left`/`Top`/`Right`/`Bottom`); `Horizontal`/`Vertical`/
    # `All` don't apply and raise (see `#raise_multi_side`). Shared skeleton
    # behind `#width_of` and (write-direction) `#set_width`/`#set_color`/
    # `#set_current_color` below.
    private macro side_read(side, suffix)
      case {{ side }}
      in .top?                           then @top{{ suffix.id }}
      in .right?                         then @right{{ suffix.id }}
      in .bottom?                        then @bottom{{ suffix.id }}
      in .left?                          then @left{{ suffix.id }}
      in .horizontal?, .vertical?, .all? then raise_multi_side {{ side }}
      end
    end

    # Writes *value* into one side's `@<side><suffix>` ivar, keyed by *side*.
    # Same single-side-only contract as `#side_read`.
    private macro side_write(side, suffix, value)
      case {{ side }}
      in .top?                           then @top{{ suffix.id }} = {{ value }}
      in .right?                         then @right{{ suffix.id }} = {{ value }}
      in .bottom?                        then @bottom{{ suffix.id }} = {{ value }}
      in .left?                          then @left{{ suffix.id }} = {{ value }}
      in .horizontal?, .vertical?, .all? then raise_multi_side {{ side }}
      end
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

    # `currentColor` markers, one per color slot. CSS resolves `currentColor`
    # at computed-value time — against the element's FINAL `color`, regardless
    # of declaration order within a rule or which rule supplied the color — so
    # the CSS appliers record the keyword here (besides eagerly storing the
    # text color known at apply time) and the border draw path re-resolves the
    # marked slots against the widget's effective fg via `#side_fg`.
    property? fg_current_color = false
    property? top_fg_current_color = false
    property? right_fg_current_color = false
    property? bottom_fg_current_color = false
    property? left_fg_current_color = false

    # Sets/clears one side's `currentColor` marker (the marker analog of
    # `set_color`).
    protected def set_current_color(side : Side, value : Bool) : Nil
      side_write side, "_fg_current_color", value
    end

    # Clears every per-side `currentColor` marker (used when the whole-border
    # `border-color` shorthand also clears the per-side color overrides).
    protected def clear_side_current_colors : Nil
      @top_fg_current_color = @right_fg_current_color =
        @bottom_fg_current_color = @left_fg_current_color = false
    end

    # Render-time per-side color: like `#top_fg` & co. but with the
    # `currentColor` markers resolved against *el_fg*, the element's effective
    # text color. Fallback order mirrors the plain getters — a concrete
    # per-side override still wins over a whole-border `currentColor`.
    def side_fg(side : Side, el_fg : Int32?) : Int32?
      side_current, own =
        case side
        in .top?                           then {@top_fg_current_color, @top_fg}
        in .right?                         then {@right_fg_current_color, @right_fg}
        in .bottom?                        then {@bottom_fg_current_color, @bottom_fg}
        in .left?                          then {@left_fg_current_color, @left_fg}
        in .horizontal?, .vertical?, .all? then raise_multi_side side
        end
      color =
        if side_current
          el_fg
        elsif own
          own
        elsif @fg_current_color
          el_fg
        else
          @fg
        end
      # Any per-side setting — a concrete `border-top-color` or a per-side
      # `currentColor` — is the author's explicit choice for that edge and is
      # left alone; the relief shading only derives the two lit/shaded edges
      # from a *whole-border* color.
      return color if own || side_current
      shade_for_relief color, side
    end

    # The CSS 3D border styles. A terminal draws a single-cell line, so the
    # carved/embossed look comes from *shading* — the light source sits top-left,
    # so `Inset`/`Groove` darken the top/left edges and lighten the bottom/right,
    # `Outset`/`Ridge` the reverse. At one cell there is no second line to draw,
    # so `Groove`/`Ridge` coincide with `Inset`/`Outset`; they are kept distinct
    # so a wider border (or a future double-line rendition) can tell them apart,
    # and so the CSS value round-trips.
    enum Relief
      None
      Inset
      Outset
      Groove
      Ridge

      # Whether this relief darkens the top/left edges (vs. the bottom/right).
      def dark_near? : Bool
        inset? || groove?
      end
    end

    # 3D relief applied to the border's derived per-side colors (CSS
    # `border-style: inset|outset|groove|ridge`); `None` for the flat styles.
    property relief : Relief = Relief::None

    # How far a relief shade moves a color toward black/white.
    RELIEF_SHADE = 0.45

    # *color* shaded for *side* under the current `#relief` — unchanged when the
    # border is flat or the color is unknown (`nil`)/`transparent` (`-1`), which
    # have nothing to shade.
    private def shade_for_relief(color : Int32?, side : Side) : Int32?
      return color if @relief.none? || color.nil? || color == -1
      near = side.top? || side.left?
      toward = (near == @relief.dark_near?) ? 0x000000 : 0xFFFFFF
      Colors.mix_resolved toward, color, RELIEF_SHADE, fg: true
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

    # Per-side run overrides; each falls back to its axis group
    # (`horizontal_char` for top/bottom, `vertical_char` for left/right). These
    # are what let one edge differ from its opposite — a solid top rule over a
    # dotted bottom — which the axis groups alone can't express.
    @top_char : Char? = nil
    @right_char : Char? = nil
    @bottom_char : Char? = nil
    @left_char : Char? = nil

    setter top_char, right_char, bottom_char, left_char

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

    # Per-side chars for a `Fill` border: side override → axis group →
    # `fill_char`. A line border resolves the same overrides against its glyph
    # family instead (see `#line_glyphs_with_overrides`).
    def top_char : Char
      @top_char || horizontal_char
    end

    # :ditto:
    def bottom_char : Char
      @bottom_char || horizontal_char
    end

    # :ditto:
    def left_char : Char
      @left_char || vertical_char
    end

    # :ditto:
    def right_char : Char
      @right_char || vertical_char
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
      !SidedGeometry.all_nil?(horizontal_char, vertical_char, corner_char,
        top_char, right_char, bottom_char, left_char,
        top_left_char, top_right_char, bottom_left_char, bottom_right_char)
    end

    # The eight glyphs of a line-family border — four corners plus one run per
    # side — with this border's char overrides merged in: each position takes
    # its own override, else its group (`corner_char` for the corners,
    # `horizontal_char`/`vertical_char` for the runs), else the `BorderType`
    # family glyph at *tier*. The no-override fast path just fans the family's
    # two run glyphs out over the four sides.
    def line_glyphs_with_overrides(tier : Glyphs::Tier)
      g = @type.line_glyphs(tier)
      unless chars?
        return {tl: g[:tl], tr: g[:tr], bl: g[:bl], br: g[:br],
                t: g[:h], b: g[:h], l: g[:v], r: g[:v]}
      end
      {tl: @top_left_char || @corner_char || g[:tl],
       tr: @top_right_char || @corner_char || g[:tr],
       bl: @bottom_left_char || @corner_char || g[:bl],
       br: @bottom_right_char || @corner_char || g[:br],
       t:  @top_char || @horizontal_char || g[:h],
       b:  @bottom_char || @horizontal_char || g[:h],
       l:  @left_char || @vertical_char || g[:v],
       r:  @right_char || @vertical_char || g[:v]}
    end

    # The eight glyphs of one border's cells — four corners plus one run per
    # side — for *either* family, so the renderer resolves them once per widget
    # instead of re-dispatching the family (and re-walking the fall-back chains)
    # on every border cell. Also spares a `Fill` border the line-family glyph
    # build it would otherwise discard.
    #
    # The two families keep their own, distinct fall-back chains: a line border
    # resolves position → group → `BorderType` family glyph at *tier* (see
    # `#line_glyphs_with_overrides`), a `Fill` border position → group →
    # `#fill_char` (see `#top_char`/`#horizontal_char`/`#top_left_char` …). Both
    # produce the same `NamedTuple` shape, so the render call site stays
    # monomorphic.
    def glyph_octet(tier : Glyphs::Tier)
      return line_glyphs_with_overrides(tier) if @type.line_family?
      {tl: top_left_char, tr: top_right_char, bl: bottom_left_char, br: bottom_right_char,
       t: top_char, b: bottom_char, l: left_char, r: right_char}
    end

    # Assigns the per-position char override for a CSS longhand, keyed by
    # *position*. Only called by `CSS::Properties`, so kept `protected`.
    protected def set_char(position : CharPosition, value : Char?) : Nil
      case position
      in .top_left?     then @top_left_char = value
      in .top_right?    then @top_right_char = value
      in .bottom_left?  then @bottom_left_char = value
      in .bottom_right? then @bottom_right_char = value
      in .top?          then @top_char = value
      in .right?        then @right_char = value
      in .bottom?       then @bottom_char = value
      in .left?         then @left_char = value
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
      in Side, Symbol
        # A side (`Side::Right`, `Side::Horizontal`, ...) or its symbol alias
        # (`:right`, `:horizontal`, ...) — one cell on the named side(s).
        SidedGeometry.new_from_side value
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
      side_write side, "", value
    end

    # Sets one side's `<side>_fg` override slot, not the whole-border `#fg`.
    # Only called by `CSS::Properties`, so kept `protected`. *side* must
    # be a single side; `Horizontal`/`Vertical`/`All` raise (see `#set_width`).
    protected def set_color(side : Side, value : Int32?) : Nil
      side_write side, "_fg", value
    end

    # Current width of one side, keyed by *side*. Only called by
    # `CSS::Properties`, so kept `protected`. *side* must be a single
    # side; `Horizontal`/`Vertical`/`All` raise (see `#set_width`).
    protected def width_of(side : Side) : Int32
      side_read side, ""
    end
  end
end
