module Crysterm
  # Type of border to draw.
  enum BorderType
    Fill    # Solid fill color (a fill character)
    Solid   # Solid line, drawn in light box-drawing chars
    Dashed  # Dashed line (light box-drawing dashes)
    Dotted  # Dotted line (light box-drawing dots)
    Double  # Double line
    Rounded # Solid light line with arc (rounded) corners: ╭╮╰╯

    # The block families: ink drawn as edge-anchored block glyphs (`▔▁▏▕`,
    # `▀▄▌▐`, …) sized by `Border#ratio`, splitting each border cell into
    # exactly two parts — ink and one ground — instead of the line families'
    # centered rule with the background showing on both sides of it.
    #
    # `Outer` anchors the ink flush with the widget's outermost cell edges and
    # grounds the cell remainder in the widget's own background, so the
    # interior runs up to the ink and stops. `Inner` anchors the ink flush
    # with the content and leaves the remainder transparent, so whatever is
    # behind the widget shows right up to the ink (an explicit `Border#bg`
    # overrides either ground).
    Outer
    Inner

    # DotDash
    # DotDotDash

    # Whether this is a block-family border — edge-anchored block ink sized by
    # `Border#ratio` — as opposed to the line families' fixed box-drawing
    # glyphs or the `Fill` fill-character border.
    def block_family?
      outer? || inner?
    end

    # Whether this is a line-drawing border, as opposed to the `Fill`
    # fill-character one or the block (`Outer`/`Inner`) families. Every line
    # family uses box-drawing glyphs; only their glyph set differs.
    def line_family?
      self != Fill && !block_family?
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

    # Ink thickness of a block-family border (`BorderType::Outer`/`Inner`), as
    # a fraction of the cell *width*: `1.0` is a full column of ink, `0.125`
    # the finest expressible eighth. Left/right runs use it directly;
    # top/bottom runs divide by the measured cell aspect ratio
    # (`CSS::Length.cell_aspect_ratio`, ~2.0), so all four edges come out
    # equally thick *on screen* rather than in cell fractions. Each axis then
    # quantizes to what the active glyph tier can express
    # (`Glyphs::SeqRole::BorderRamp*`): the `Extended` tier renders every
    # eighth exactly, while below it each axis snaps to the 1/8, 4/8 and 8/8
    # steps its two ramps share — opposite edges of the frame always match —
    # making `0.125` and `1.0` the ratios that render identically at every
    # tier. Ignored by the line families and `Fill`. See `#ratio=(Symbol)`
    # for the named presets.
    property ratio : Float64 = 0.5

    # Sets `#ratio` by named preset: `:thin` (an eighth), `:quarter`, `:half`,
    # `:full` (see `Glyphs::BLOCK_RATIOS`).
    def ratio=(name : Symbol)
      @ratio = Glyphs::BLOCK_RATIOS[name.to_s]? ||
               raise ArgumentError.new "Unknown border ratio #{name.inspect} (known: #{Glyphs::BLOCK_RATIOS.keys.join(", ")})"
    end

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
    def line_glyphs_with_overrides(tier : Glyphs::Tier, cap_v = false, cap_h = false)
      g = @type.line_glyphs(tier)
      # Run glyph per axis: the family's own, unless that axis' pair is standing
      # alone because the perpendicular edges didn't fit, in which case the caps
      # take over (see `Glyphs::Role::BorderCapLeft`). The four cap roles stay
      # separate so a theme can give each edge its own rendition, even though the
      # registry defaults them all to the same block.
      vl = cap_v ? Glyphs[Glyphs::Role::BorderCapLeft, tier] : g[:v]
      vr = cap_v ? Glyphs[Glyphs::Role::BorderCapRight, tier] : g[:v]
      ht = cap_h ? Glyphs[Glyphs::Role::BorderCapTop, tier] : g[:h]
      hb = cap_h ? Glyphs[Glyphs::Role::BorderCapBottom, tier] : g[:h]
      unless chars?
        return {tl: g[:tl], tr: g[:tr], bl: g[:bl], br: g[:br],
                t: ht, b: hb, l: vl, r: vr}
      end
      # An explicit char override is the author's choice and outranks the cap,
      # which is only the last link of each fall-back chain.
      {tl: @top_left_char || @corner_char || g[:tl],
       tr: @top_right_char || @corner_char || g[:tr],
       bl: @bottom_left_char || @corner_char || g[:bl],
       br: @bottom_right_char || @corner_char || g[:br],
       t:  @top_char || @horizontal_char || ht,
       b:  @bottom_char || @horizontal_char || hb,
       l:  @left_char || @vertical_char || vl,
       r:  @right_char || @vertical_char || vr}
    end

    # The eight glyphs of a block-family border (`Outer`/`Inner`): each run an
    # edge-anchored block glyph `#ratio` thick (aspect-compensated and
    # tier-quantized via `Glyphs.block_eighths` and the
    # `Glyphs::SeqRole::BorderRamp*` step tables), each corner the matching
    # joint — an `Outer` corner is the L-shaped elbow hugging the two outer
    # edges (stepped by the thicker arm, so a full-column side closes with a
    # full corner), an `Inner` corner the horizontal run continued through
    # the corner cell (see the `else` branch below).
    #
    # Same char-override chain as the line families. The one-axis cap
    # substitution (`Glyphs::Role::BorderCapLeft` …) doesn't apply: an
    # edge-anchored run sits flush against the cell edge already and reads as
    # a trough wall on its own, which is all the caps exist to provide.
    def block_glyphs_with_overrides(tier : Glyphs::Tier)
      w8, v8 = Glyphs.block_eighths(@ratio)
      # Below the Extended tier the upper/right ramps only offer the 1/8, 4/8
      # and 8/8 steps. A frame's opposite edges must match, so quantize each
      # axis to that shared sub-set rather than letting the rich (lower/left)
      # ramp resolve finer than its partner across the box.
      unless tier.extended?
        w8, v8 = coarse_step(w8), coarse_step(v8)
      end
      upper = Glyphs.chars(Glyphs::SeqRole::BorderRampUpper, tier)
      lower = Glyphs.chars(Glyphs::SeqRole::BorderRampLower, tier)
      lefts = Glyphs.chars(Glyphs::SeqRole::BorderRampLeft, tier)
      rights = Glyphs.chars(Glyphs::SeqRole::BorderRampRight, tier)
      if @type.outer?
        ci = Math.max(w8, v8) - 1
        t, b, l, r = upper[v8 - 1], lower[v8 - 1], lefts[w8 - 1], rights[w8 - 1]
        tl = Glyphs.chars(Glyphs::SeqRole::BorderElbowTL, tier)[ci]
        tr = Glyphs.chars(Glyphs::SeqRole::BorderElbowTR, tier)[ci]
        bl = Glyphs.chars(Glyphs::SeqRole::BorderElbowBL, tier)[ci]
        br = Glyphs.chars(Glyphs::SeqRole::BorderElbowBR, tier)[ci]
      else
        # Inner: every anchor flips to the content-facing edge, so each ramp
        # serves the opposite side. Corners continue the horizontal runs
        # through the corner cells — the ring's horizontal strokes span the
        # full box width at their own thickness and the vertical bars meet
        # them flush. (No repertoire has a corner square smaller than a
        # quadrant, and a quadrant bead beside a thin run reads as a stray
        # tick; a continued stroke just reaches the box edge.)
        t, b, l, r = lower[v8 - 1], upper[v8 - 1], rights[w8 - 1], lefts[w8 - 1]
        tl = tr = t
        bl = br = b
      end
      unless chars?
        return {tl: tl, tr: tr, bl: bl, br: br, t: t, b: b, l: l, r: r}
      end
      {tl: @top_left_char || @corner_char || tl,
       tr: @top_right_char || @corner_char || tr,
       bl: @bottom_left_char || @corner_char || bl,
       br: @bottom_right_char || @corner_char || br,
       t:  @top_char || @horizontal_char || t,
       b:  @bottom_char || @horizontal_char || b,
       l:  @left_char || @vertical_char || l,
       r:  @right_char || @vertical_char || r}
    end

    # Nearest step in the coarse `{1, 4, 8}` eighth sub-set — the steps the
    # upper/right ramps offer below the `Extended` tier (matching those ramp
    # arrays' own bucketing, so the quantized step always reads back exactly).
    private def coarse_step(n : Int32) : Int32
      n <= 2 ? 1 : n <= 5 ? 4 : 8
    end

    # The eight glyphs of one border's cells — four corners plus one run per
    # side — for *any* family, so the renderer resolves them once per widget
    # instead of re-dispatching the family (and re-walking the fall-back chains)
    # on every border cell. Also spares a `Fill` border the line-family glyph
    # build it would otherwise discard.
    #
    # The families keep their own, distinct fall-back chains: a line border
    # resolves position → group → `BorderType` family glyph at *tier* (see
    # `#line_glyphs_with_overrides`), a block border position → group → ramp
    # step at `#ratio` (see `#block_glyphs_with_overrides`), a `Fill` border
    # position → group → `#fill_char` (see `#top_char`/`#horizontal_char`/
    # `#top_left_char` …). All produce the same `NamedTuple` shape, so the
    # render call site stays monomorphic.
    # *cap_v*/*cap_h* say that this render dropped a pair of edges that did not
    # fit the box (`Widget#effective_insets`), leaving the perpendicular pair
    # standing alone: *cap_v* when the left/right edges survive without a
    # top/bottom to close them, *cap_h* for the transpose. A `Fill` border
    # paints colored cells and a block border edge-flush runs — neither implies
    # a shape the caps must repair, so both ignore them.
    def glyph_octet(tier : Glyphs::Tier, cap_v = false, cap_h = false)
      return block_glyphs_with_overrides(tier) if @type.block_family?
      return line_glyphs_with_overrides(tier, cap_v, cap_h) if @type.line_family?
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
        # A symbol naming a border type (`:rounded`, `:outer`, …) — that
        # family at the default 1-cell box. No `BorderType` member collides
        # with a side name, so the two symbol vocabularies coexist.
        if value.is_a?(Symbol) && (bt = BorderType.parse?(value.to_s))
          return Border.new(bt)
        end
        # Else a side (`Side::Right`, `Side::Horizontal`, ...) or its symbol
        # alias (`:right`, `:horizontal`, ...) — one cell on the named side(s).
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
      ratio : (Float64 | Symbol)? = nil,
    )
      # Route through setters so a native int or a `"#rrggbb"`/named string
      # both resolve to the native int form — and a `ratio` given as a named
      # preset (`:thin`, `:half`, …) to its fraction.
      self.bg = bg unless bg.nil?
      self.fg = fg unless fg.nil?
      case ratio
      in Float64 then self.ratio = ratio
      in Symbol  then self.ratio = ratio
      in Nil
      end
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
