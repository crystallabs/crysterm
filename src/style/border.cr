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

    # Braille-dot border: runs and corners drawn as Braille Patterns
    # (U+2800..), the ink hugging the widget's outermost cell edges like
    # `Outer` — and grounded the same way, in the widget's own background —
    # but dotted rather than solid, at the braille grid's 2 dot-columns x
    # 4 dot-rows resolution. `Border#ratio` sizes the ink in dot-lines
    # (`Glyphs.braille_steps`, aspect-compensated like the block families):
    # up to `:half` a single dot-line on every edge, `:full` the whole
    # two-column band. Corner cells take the union of the two adjoining
    # runs' dots, so the ring closes flush. Braille is Extended-tier
    # repertoire (same taxonomy as the braille spinner frames); below that
    # tier the border degrades to the `Dotted` line family's glyphs.
    Braille

    # The bare-medium spellings, so `type:` is the one "what kind of
    # border" knob: `Line` is the line medium at its defaults (≡ `Solid`),
    # `Block` the block medium at its natural outer anchoring (≡ `Outer`).
    # `Braille` and `Fill` above already double as their media's names.
    # Reading `Border#type` back collapses these onto their equivalents.
    Line
    Block

    # DotDash
    # DotDotDash

    # The medium (ink kind) this preset names — the kind component of the
    # `type` axis: `Solid`/`Dashed`/`Dotted`/`Double`/`Rounded`/`Line` draw
    # box-drawing glyphs, `Outer`/`Inner`/`Block` edge-anchored block ink,
    # `Braille` dot patterns, `Fill` whole-cell fill.
    def medium : Border::Medium
      case self
      in .fill?                    then Border::Medium::Fill
      in .braille?                 then Border::Medium::Braille
      in .outer?, .inner?, .block? then Border::Medium::Block
      in .solid?, .dashed?, .dotted?,
         .double?, .rounded?, .line? then Border::Medium::Line
      end
    end

    # The dash pattern this preset names (`Border#pattern`'s component):
    # `Dashed`/`Dotted`/`Double` their own, everything else `Solid`.
    def pattern : Border::Pattern
      case self
      when .dashed? then Border::Pattern::Dashed
      when .dotted? then Border::Pattern::Dotted
      when .double? then Border::Pattern::Double
      else               Border::Pattern::Solid
      end
    end

    # Whether this is a block-family border — edge-anchored block ink sized by
    # `Border#ratio` — as opposed to the line families' fixed box-drawing
    # glyphs or the `Fill` fill-character border.
    def block_family?
      outer? || inner? || block?
    end

    # Whether this is a line-drawing border, as opposed to the `Fill`
    # fill-character one, the block (`Outer`/`Inner`) families or the
    # dot-ink `Braille` one. Every line family uses box-drawing glyphs; only
    # their glyph set differs.
    def line_family?
      self != Fill && !block_family? && !braille?
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

    # -- The stroke axes -----------------------------------------------------
    # A border is a stroke around the widget, decomposed into orthogonal
    # axes (see plans/BORDERS.md): what kind of border it is (`#type` — the
    # one knob naming both the media, `:line`/`:block`/`:braille`/`:fill`,
    # and the richer presets, `:rounded`/`:outer`/`:dotted`/…, which fan out
    # over several axes at once), the dash pattern along the runs
    # (`#pattern`), where the ink sits in the border band (`#align`), its
    # sub-cell thickness (`#ratio`, and `#corner_ratio` for the corners
    # alone), and the per-corner treatment (`#corners`). A combination with
    # no exact glyphs *rounds down* to the most similar achievable rendition
    # (toward the thinner/simpler look), it never errors.

    # The ink kind component of the `#type` axis. Internal: publicly the
    # kind is spelled through `type` (`BorderType::Line`/`Block`/`Braille`/
    # `Fill` name the bare media); this enum remains the render dispatch and
    # the axis-only spelling the CSS multi-token composition sets without
    # disturbing the pattern/alignment (see `CSS::Properties`).
    enum Medium
      Line    # box-drawing glyphs (the five line families)
      Block   # edge-anchored block ramps (`▀▌…`, the Outer/Inner presets)
      Braille # braille dot patterns (U+2800..)
      Fill    # whole-cell fill (`#fill_char` + colors)
    end

    # The dash pattern along the runs (Qt `PenStyle`). `Double` lives here —
    # it is a run treatment, not a corner or medium one.
    enum Pattern
      Solid
      Dashed
      Dotted
      Double
    end

    # Where the ink sits inside the border band (stroke alignment:
    # inside/center/outside in design-tool terms). The line families draw a
    # centered rule; the block/braille media anchor flush with the widget's
    # outermost edge (`Outer`, cell remainder grounded in the widget's own
    # bg) or with the content (`Inner`, remainder transparent by default).
    # A medium without glyphs for the requested alignment rounds down
    # (block/braille `Center` → `Outer`; line `Outer`/`Inner` ≡ `Center` at
    # 1-cell widths).
    enum Align
      Center
      Outer
      Inner
    end

    # A corner's treatment (Qt `joinStyle` / CSS `border-radius`).
    enum Corner
      Square  # miter — the families' own corner pieces
      Rounded # arc: line `╭`; braille drops the apex dot; block → `Cut`
      Cut     # bevel/chamfer: line `╱`; braille a diagonal dot pair
    end

    # The four per-corner treatments plus per-corner radii. The radii are
    # accepted and stored (CSS `border-radius: 2ch` round-trips) but render
    # clamped to 1 for now — multi-cell arcs are future work; see
    # plans/BORDERS.md § 3.3.
    record Corners,
      tl : Corner = Corner::Square, tr : Corner = Corner::Square,
      bl : Corner = Corner::Square, br : Corner = Corner::Square,
      radii : {Int32, Int32, Int32, Int32} = {1, 1, 1, 1} do
      # Coerces a uniform spelling: a `Corner` (or its symbol) applied to
      # all four corners; a `Corners` passes through.
      def self.from(value : Corners | Corner | Symbol) : Corners
        case value
        in Corners then value
        in Corner  then new value, value, value, value
        in Symbol
          c = Corner.parse value.to_s
          new c, c, c, c
        end
      end

      # The single treatment all four corners share, or `nil` when mixed.
      def uniform : Corner?
        tl if tl == tr && tr == bl && bl == br
      end
    end

    getter pattern : Pattern = Pattern::Solid
    getter align : Align = Align::Center
    getter corners : Corners = Corners.new

    # The ink kind, internal (see `Medium`): read the public `#type` view
    # instead, set the kind with `type = :line/:block/:braille/:fill` (a
    # bare-medium preset). This axis-only setter exists for the CSS
    # multi-token composition, which must switch the kind without resetting
    # the pattern/alignment a sibling token set.
    protected getter medium : Medium = Medium::Line

    protected def medium=(value : Medium | Symbol)
      @medium = value.is_a?(Symbol) ? Medium.parse(value.to_s) : value
    end

    def pattern=(value : Pattern | Symbol)
      @pattern = value.is_a?(Symbol) ? Pattern.parse(value.to_s) : value
    end

    def align=(value : Align | Symbol)
      @align = value.is_a?(Symbol) ? Align.parse(value.to_s) : value
    end

    def corners=(value : Corners | Corner | Symbol)
      @corners = Corners.from value
    end

    # Sets the axes to *preset*'s point in the axis space (the table in
    # plans/BORDERS.md § 3.2) — `type` is the one "what kind of border"
    # knob, its vocabulary covering both the bare media (`:line`/`:block`/
    # `:braille`/`:fill`) and the richer presets. The other axes stay
    # individually overridable afterwards.
    def type=(preset : BorderType)
      @medium, @pattern, @align, corner =
        case preset
        in .fill?           then {Medium::Fill, Pattern::Solid, Align::Center, Corner::Square}
        in .solid?, .line?  then {Medium::Line, Pattern::Solid, Align::Center, Corner::Square}
        in .dashed?         then {Medium::Line, Pattern::Dashed, Align::Center, Corner::Square}
        in .dotted?         then {Medium::Line, Pattern::Dotted, Align::Center, Corner::Square}
        in .double?         then {Medium::Line, Pattern::Double, Align::Center, Corner::Square}
        in .rounded?        then {Medium::Line, Pattern::Solid, Align::Center, Corner::Rounded}
        in .outer?, .block? then {Medium::Block, Pattern::Solid, Align::Outer, Corner::Square}
        in .inner?          then {Medium::Block, Pattern::Solid, Align::Inner, Corner::Square}
        in .braille?        then {Medium::Braille, Pattern::Solid, Align::Outer, Corner::Square}
        end
      @corners = Corners.from corner
      preset
    end

    # The nearest `BorderType` preset for the current axes — the lossy
    # compat view (`type = :dotted; type # => Dotted` round-trips exactly;
    # an off-preset combination reads back as its base preset, and the
    # bare-medium spellings collapse onto their equivalents: `:line` reads
    # back `Solid`, `:block` reads back `Outer`).
    def type : BorderType
      case @medium
      in .fill?    then BorderType::Fill
      in .braille? then BorderType::Braille
      in .block?   then @align.inner? ? BorderType::Inner : BorderType::Outer
      in .line?
        return BorderType::Rounded if @pattern.solid? && @corners.uniform.try(&.rounded?)
        case @pattern
        in .solid?  then BorderType::Solid
        in .dashed? then BorderType::Dashed
        in .dotted? then BorderType::Dotted
        in .double? then BorderType::Double
        end
      end
    end

    # Whether the border's ground (the border cells' remainder around the
    # ink) defaults to transparent — an `Inner`-aligned block/braille ring
    # hugs the content, so by definition of the family whatever is behind
    # the widget shows up to the ink. An explicit `#bg` always overrides;
    # the render path keys off this instead of the legacy `type.inner?`.
    def transparent_ground_default? : Bool
      @align.inner? && (@medium.block? || @medium.braille?)
    end

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
    # tier. A `Braille` border reads it too, quantized to the braille grid's
    # coarser dot-lines instead (`Glyphs.braille_steps`). Ignored by the line
    # families and `Fill`. See `#ratio=(Symbol)` for the named presets.
    property ratio : Float64 = 0.5

    # Sets `#ratio` by named preset: `:thin` (an eighth), `:quarter`, `:half`,
    # `:full` (see `Glyphs::BLOCK_RATIOS`).
    def ratio=(name : Symbol)
      @ratio = Glyphs::BLOCK_RATIOS[name.to_s]? ||
               raise ArgumentError.new "Unknown border ratio #{name.inspect} (known: #{Glyphs::BLOCK_RATIOS.keys.join(", ")})"
    end

    # The corners' own ink thickness, independent of the runs' `#ratio` —
    # unset (`nil`), corners follow the runs exactly. Setting it decorates
    # the frame with corner *beads*: a hairline block ring with quadrant
    # corner mounts (`ratio: :thin, corner_ratio: :half` → `▏▔` runs, `▛`
    # corners), heavy corner joins on light line runs (`┏` on `─`), or
    # full-dot corner blocks on a one-dot braille ring (`⣿` on `⠉`). Above
    # `:half` a line medium's corners go heavy; a block medium's corners
    # resolve on the solid elbow ladder (eighth-L → quadrant → full block)
    # at this step instead of the runs'. Ignored where no bigger corner
    # piece exists (rounds down, § 3.1 of plans/BORDERS.md).
    property corner_ratio : Float64? = nil

    # Sets `#corner_ratio` by the same named presets as `#ratio=`.
    def corner_ratio=(name : Symbol)
      @corner_ratio = Glyphs::BLOCK_RATIOS[name.to_s]? ||
                      raise ArgumentError.new "Unknown border corner_ratio #{name.inspect} (known: #{Glyphs::BLOCK_RATIOS.keys.join(", ")})"
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
    def side_fg(side : Side, el_fg : Int32?, light : Light = Light::DEFAULT) : Int32?
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
      # left alone; the relief shading only derives the lit/shaded edges
      # from a *whole-border* color.
      return color if own || side_current
      shade_for_relief color, side, light
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

    # :ditto: by symbol (`:outset`, ...).
    def relief=(name : Symbol)
      @relief = Relief.parse name.to_s
    end

    # How a non-`None` `#relief` is *expressed* on the border's glyphs and
    # colors. `Shade` is the classic color treatment (per-side shading
    # toward black/white). `Weight` renders the same lit/shaded
    # classification in glyph weight instead: the emphasized sides take
    # their pattern's heavy rendition (`━ ┃`, `┅ ┇`, `┉ ┋`), the others keep
    # its light runs, and the corners resolve to the matching mixed-weight
    # joins (`┏ ┑ ┖` under the default NW light) — the bevel look
    # styling.cr used to hand-assemble from five char overrides.
    # `Outset`/`Ridge` emphasize the lit sides (raised edge catches the
    # light), `Inset`/`Groove` the shaded ones. Media without a weight
    # vocabulary round down per plans/BORDERS.md § 3.1: block bumps the
    # emphasized sides' ink one eighth, braille one dot-line, a `Double`
    # pattern keeps `Shade` behavior.
    enum ReliefStyle
      Shade
      Weight
      Both
    end

    # The active relief rendition; only consulted when `#relief` is not
    # `None`.
    property relief_style : ReliefStyle = ReliefStyle::Shade

    # :ditto: by symbol (`:weight`, ...).
    def relief_style=(name : Symbol)
      @relief_style = ReliefStyle.parse name.to_s
    end

    # How far a relief shade moves a color toward black/white.
    RELIEF_SHADE = 0.45

    # Whether the weight rendition emphasizes *side* under *light*: the
    # relief is on and expressed in weight, the side is lit/shaded (not
    # neutral — a cardinal light leaves the two parallel sides alone), and
    # the relief's polarity picks which of the two it thickens.
    protected def weight_side?(side : Side, light : Light) : Bool
      return false if @relief.none?
      return false unless @relief_style.weight? || @relief_style.both?
      lit = light.lit(side)
      return false if lit.zero?
      (lit > 0) != @relief.dark_near?
    end

    # *color* shaded for *side* under the current `#relief` and *light* —
    # unchanged when the border is flat, the side is neutral to the light,
    # or the color is unknown (`nil`)/`transparent` (`-1`), which have
    # nothing to shade. Also unchanged when the relief is expressed purely
    # in `Weight` — the glyphs carry the effect there, not the colors.
    private def shade_for_relief(color : Int32?, side : Side, light : Light) : Int32?
      return color if @relief.none? || color.nil? || color == -1
      return color if @relief_style.weight?
      lit = light.lit side
      return color if lit.zero?
      toward = ((lit > 0) == @relief.dark_near?) ? 0x000000 : 0xFFFFFF
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

    # The line family whose glyphs the `Glyphs` registry serves for the
    # current `#pattern`. The corners axis and the weight machinery pick
    # their own pieces on top of it.
    private def line_base_family : BorderType
      case @pattern
      in .double? then BorderType::Double
      in .dashed? then BorderType::Dashed
      in .dotted? then BorderType::Dotted
      in .solid?  then BorderType::Solid
      end
    end

    # The heavy run glyph for one axis of the current pattern, or `nil` when
    # the pattern has no heavy rendition (`Double` is already the heaviest
    # spelling of its family).
    private def heavy_run(tier : Glyphs::Tier, horizontal : Bool) : Char?
      role =
        case @pattern
        in .solid?  then horizontal ? Glyphs::Role::BorderHeavyH : Glyphs::Role::BorderHeavyV
        in .dashed? then horizontal ? Glyphs::Role::BorderHeavyDashedH : Glyphs::Role::BorderHeavyDashedV
        in .dotted? then horizontal ? Glyphs::Role::BorderHeavyDottedH : Glyphs::Role::BorderHeavyDottedV
        in .double? then return
        end
      Glyphs[role, tier]
    end

    # Merges the explicit char overrides over a derived octet — the tail
    # every medium's builder shares: each position takes its own override,
    # else its group (`corner_char` for the corners, `horizontal_char`/
    # `vertical_char` for the runs), else the derived glyph. An explicit
    # char override is the author's choice and outranks even the caps,
    # which are only the last link of each fall-back chain.
    private def merge_char_overrides(tl : Char, tr : Char, bl : Char, br : Char,
                                     t : Char, b : Char, l : Char, r : Char)
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

    # The square (miter) join for arm weights: heavy when both arms are,
    # the mixed-weight joins (`┍`/`┎` …) when only one is, the base family
    # corner when neither. A `Double` pattern has no weight pieces and keeps
    # its own corners.
    private def square_corner(tier : Glyphs::Tier, base : Char, arm_h : Bool, arm_v : Bool,
                              heavy : Glyphs::Role, mixed_h : Glyphs::Role, mixed_v : Glyphs::Role) : Char
      return base if @pattern.double?
      if arm_h && arm_v
        Glyphs[heavy, tier]
      elsif arm_h
        Glyphs[mixed_h, tier]
      elsif arm_v
        Glyphs[mixed_v, tier]
      else
        base
      end
    end

    # One corner glyph of a line border: the per-corner `Corner` treatment
    # resolved against the adjoining arms' weights (*arm_h* is the
    # horizontal run's, *arm_v* the vertical's). An explicit `#corner_ratio`
    # outranks the run-derived weights — above `:half` the corner is a
    # heavy bead on both arms (`┏` joins on `─` runs), at or below it stays
    # light. The arc pieces exist only light-weight, so a rounded corner
    # with a heavy arm (or the arc-less `Double` pattern) rounds down to the
    # square join.
    private def line_corner_glyph(tier : Glyphs::Tier, base : Char, style : Corner,
                                  arm_h : Bool, arm_v : Bool,
                                  rounded : Glyphs::Role, cut : Glyphs::Role,
                                  heavy : Glyphs::Role, mixed_h : Glyphs::Role, mixed_v : Glyphs::Role) : Char
      if cr = @corner_ratio
        arm_h = arm_v = cr > 0.5 && !@pattern.double?
      end
      case style
      in .cut?
        Glyphs[cut, tier]
      in .rounded?
        return Glyphs[rounded, tier] unless @pattern.double? || arm_h || arm_v
        square_corner tier, base, arm_h, arm_v, heavy, mixed_h, mixed_v
      in .square?
        square_corner tier, base, arm_h, arm_v, heavy, mixed_h, mixed_v
      end
    end

    # The eight glyphs of a line-medium border — four corners plus one run
    # per side — with this border's char overrides merged in: each position
    # takes its own override, else its group (`corner_char` for the corners,
    # `horizontal_char`/`vertical_char` for the runs), else the axis-derived
    # glyph at *tier*: the `#pattern` family's run, gone heavy above
    # `#ratio` 1/2 (the line medium's reading of the thickness knob) or on
    # the weight bevel's emphasized sides (`#relief_style`, *light*), and
    # each corner its `#corners` treatment joined to match (see
    # `#line_corner_glyph`).
    def line_glyphs_with_overrides(tier : Glyphs::Tier, cap_v = false, cap_h = false,
                                   light : Light = Light::DEFAULT)
      g = line_base_family.line_glyphs(tier)
      base_heavy = !@pattern.double? && @ratio > 0.5
      hv_t = base_heavy || weight_side?(Side::Top, light)
      hv_b = base_heavy || weight_side?(Side::Bottom, light)
      hv_l = base_heavy || weight_side?(Side::Left, light)
      hv_r = base_heavy || weight_side?(Side::Right, light)
      run_h = heavy_run(tier, horizontal: true)
      run_v = heavy_run(tier, horizontal: false)
      ht = hv_t && run_h ? run_h : g[:h]
      hb = hv_b && run_h ? run_h : g[:h]
      vl = hv_l && run_v ? run_v : g[:v]
      vr = hv_r && run_v ? run_v : g[:v]
      # Run glyph per axis: the derived one, unless that axis' pair is standing
      # alone because the perpendicular edges didn't fit, in which case the caps
      # take over (see `Glyphs::Role::BorderCapLeft`). The four cap roles stay
      # separate so a theme can give each edge its own rendition, even though the
      # registry defaults them all to the same block.
      vl = Glyphs[Glyphs::Role::BorderCapLeft, tier] if cap_v
      vr = Glyphs[Glyphs::Role::BorderCapRight, tier] if cap_v
      ht = Glyphs[Glyphs::Role::BorderCapTop, tier] if cap_h
      hb = Glyphs[Glyphs::Role::BorderCapBottom, tier] if cap_h
      c = @corners
      tl = line_corner_glyph(tier, g[:tl], c.tl, hv_t, hv_l,
        Glyphs::Role::BorderRoundedTL, Glyphs::Role::BorderCutTL,
        Glyphs::Role::BorderHeavyTL, Glyphs::Role::BorderMixedHTL, Glyphs::Role::BorderMixedVTL)
      tr = line_corner_glyph(tier, g[:tr], c.tr, hv_t, hv_r,
        Glyphs::Role::BorderRoundedTR, Glyphs::Role::BorderCutTR,
        Glyphs::Role::BorderHeavyTR, Glyphs::Role::BorderMixedHTR, Glyphs::Role::BorderMixedVTR)
      bl = line_corner_glyph(tier, g[:bl], c.bl, hv_b, hv_l,
        Glyphs::Role::BorderRoundedBL, Glyphs::Role::BorderCutBL,
        Glyphs::Role::BorderHeavyBL, Glyphs::Role::BorderMixedHBL, Glyphs::Role::BorderMixedVBL)
      br = line_corner_glyph(tier, g[:br], c.br, hv_b, hv_r,
        Glyphs::Role::BorderRoundedBR, Glyphs::Role::BorderCutBR,
        Glyphs::Role::BorderHeavyBR, Glyphs::Role::BorderMixedHBR, Glyphs::Role::BorderMixedVBR)
      merge_char_overrides tl, tr, bl, br, ht, hb, vl, vr
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
    def block_glyphs_with_overrides(tier : Glyphs::Tier, octants : Bool = false,
                                    light : Light = Light::DEFAULT)
      w8, v8 = Glyphs.block_eighths(@ratio)
      # Below the Extended tier the upper/right ramps only offer the 1/8, 4/8
      # and 8/8 steps. A frame's opposite edges must match, so quantize each
      # axis to that shared sub-set rather than letting the rich (lower/left)
      # ramp resolve finer than its partner across the box.
      unless tier.extended?
        w8, v8 = coarse_step(w8), coarse_step(v8)
      end
      wt, wb, wl, wr = block_weight_bumps(light)
      weighted = wt + wb + wl + wr > 0
      upper = Glyphs.chars(Glyphs::SeqRole::BorderRampUpper, tier)
      lower = Glyphs.chars(Glyphs::SeqRole::BorderRampLower, tier)
      lefts = Glyphs.chars(Glyphs::SeqRole::BorderRampLeft, tier)
      rights = Glyphs.chars(Glyphs::SeqRole::BorderRampRight, tier)
      # When the corners resolve to sextant pieces, whose horizontal arms are
      # a *third* of the cell, 2/8- and 3/8-thick horizontal runs re-quantize
      # to the matching third-blocks: a 1/24-cell step at every corner reads
      # as a bulge, while a run drawn at 1/3 instead of 1/4 or 3/8 just reads
      # as the run — flush joints beat nominal eighth exactness. With the
      # octant pieces in play (*octants*, quarter-height arms) no such trade
      # is needed: the runs stay at their honest eighths. Per-side weight
      # bumps and explicit corner beads opt out for the same joint-honesty
      # reason.
      thirdable = tier.extended? && (v8 == 2 || v8 == 3) && !weighted && @corner_ratio.nil?
      if !@align.inner?
        v8t, v8b = (v8 + wt).clamp(1, 8), (v8 + wb).clamp(1, 8)
        w8l, w8r = (w8 + wl).clamp(1, 8), (w8 + wr).clamp(1, 8)
        octant_corners = outer_octant_corners?(tier, w8, v8, octants)
        thirds = thirdable && w8 <= 6 && !octant_corners
        t = thirds ? Glyphs[Glyphs::Role::BorderThirdUpper, tier] : upper[v8t - 1]
        b = thirds ? Glyphs[Glyphs::Role::BorderThirdLower, tier] : lower[v8b - 1]
        l, r = lefts[w8l - 1], rights[w8r - 1]
        if cr = @corner_ratio
          tl, tr, bl, br = outer_corner_beads(tier, cr)
        elsif weighted
          # Each corner joins its two adjacent runs — resolve it at those
          # arms' (possibly bumped) steps so the joint stays flush.
          tl = outer_block_corners(tier, w8l, v8t, outer_octant_corners?(tier, w8l, v8t, octants))[0]
          tr = outer_block_corners(tier, w8r, v8t, outer_octant_corners?(tier, w8r, v8t, octants))[1]
          bl = outer_block_corners(tier, w8l, v8b, outer_octant_corners?(tier, w8l, v8b, octants))[2]
          br = outer_block_corners(tier, w8r, v8b, outer_octant_corners?(tier, w8r, v8b, octants))[3]
        else
          tl, tr, bl, br = outer_block_corners(tier, w8, v8, octant_corners)
        end
      else
        # Inner: every anchor flips to the content-facing edge, so each ramp
        # serves the opposite side.
        fit = Glyphs.corner_fit(w8, v8, tier, octants)
        thirds = thirdable && fit == :sextant
        t = thirds ? Glyphs[Glyphs::Role::BorderThirdLower, tier] : lower[v8 - 1]
        b = thirds ? Glyphs[Glyphs::Role::BorderThirdUpper, tier] : upper[v8 - 1]
        l, r = rights[w8 - 1], lefts[w8 - 1]
        tl, tr, bl, br = inner_block_corners(fit, tier, t, b)
      end
      merge_char_overrides tl, tr, bl, br, t, b, l, r
    end

    # The weight bevel's per-side extra eighths of block ink `{top, bottom,
    # left, right}` — all zero unless a weight-rendition relief is on. Only
    # the outer anchoring participates (an inner ring rounds the rendition
    # down to `Shade`); the caller skips the thirds re-quantization when
    # any side is bumped, so the bumped sides keep honest eighths at their
    # corners.
    private def block_weight_bumps(light : Light) : {Int32, Int32, Int32, Int32}
      if @align.inner? || @relief.none? || @relief_style.shade?
        return {0, 0, 0, 0}
      end
      {weight_side?(Side::Top, light) ? 1 : 0,
       weight_side?(Side::Bottom, light) ? 1 : 0,
       weight_side?(Side::Left, light) ? 1 : 0,
       weight_side?(Side::Right, light) ? 1 : 0}
    end

    # The eight glyphs of a `Braille` border: each run the braille pattern
    # whose dot-columns (left/right) or dot-rows (top/bottom) hug the cell
    # edge, `#ratio` dot-lines deep (aspect-compensated and quantized to the
    # 2 x 4 braille grid via `Glyphs.braille_steps`), each corner the union
    # of its two adjoining runs' dot masks — the braille grid composes by
    # OR, so every joint is flush by construction and needs no corner-piece
    # chooser. Same char-override chain as the other families; the one-axis
    # cap substitution doesn't apply for the same reason as the block
    # families (an edge-anchored run reads as a trough wall on its own).
    def braille_glyphs_with_overrides(tier : Glyphs::Tier, light : Light = Light::DEFAULT)
      unless tier.extended?
        # Braille Patterns are Extended-tier repertoire (the taxonomy the
        # braille spinner frames set); below it the nearest look is the
        # dotted line family (dashed for a dashed pattern), whose registry
        # entries fall down to their own ascii forms at the bottom tier.
        g = (@pattern.dashed? ? BorderType::Dashed : BorderType::Dotted).line_glyphs(tier)
        return merge_char_overrides g[:tl], g[:tr], g[:bl], g[:br], g[:h], g[:h], g[:v], g[:v]
      end
      inner = @align.inner?
      tm, bm, lm, rm = braille_run_masks(inner, light)
      # Corner masks: the runs' own, or — under an explicit `#corner_ratio`
      # — the tables re-read at the corners' step, giving the full-dot
      # corner blocks on a one-dot ring (`⣿` on `⠉`).
      if cr = @corner_ratio
        cw2, cv4 = Glyphs.braille_steps(cr)
        ctm = braille_row_mask(inner, top: true, steps: cv4)
        cbm = braille_row_mask(inner, top: false, steps: cv4)
        clm = braille_col_mask(inner, left: true, steps: cw2)
        crm = braille_col_mask(inner, left: false, steps: cw2)
      else
        ctm, cbm, clm, crm = tm, bm, lm, rm
      end
      tl = braille_corner(@corners.tl, ctm | clm, inner, 0)
      tr = braille_corner(@corners.tr, ctm | crm, inner, 1)
      bl = braille_corner(@corners.bl, cbm | clm, inner, 2)
      br = braille_corner(@corners.br, cbm | crm, inner, 3)
      merge_char_overrides tl, tr, bl, br,
        Glyphs.braille(tm), Glyphs.braille(bm), Glyphs.braille(lm), Glyphs.braille(rm)
    end

    # One horizontal braille run's mask, *steps* dot-rows deep, anchored at
    # the edge the ink hugs: *top* names the widget side, and the inner
    # anchoring hugs the opposite cell edge — which is the whole of the
    # outer/inner transpose, and why the corner unions stay flush in both.
    private def braille_row_mask(inner : Bool, *, top : Bool, steps : Int32) : Int32
      hug_top = top != inner
      hug_top ? Glyphs::BRAILLE_ROWS_TOP[steps - 1] : Glyphs::BRAILLE_ROWS_BOTTOM[steps - 1]
    end

    # :ditto: for a vertical run, *steps* dot-columns wide.
    private def braille_col_mask(inner : Bool, *, left : Bool, steps : Int32) : Int32
      hug_left = left != inner
      hug_left ? Glyphs::BRAILLE_COLS_LEFT[steps - 1] : Glyphs::BRAILLE_COLS_RIGHT[steps - 1]
    end

    # The four run masks `{top, bottom, left, right}` of a braille ring:
    # the sparse patterns for a dashed/dotted pattern, else the solid tables
    # at `#ratio`'s steps — a `Double` pattern pinned to two dot-lines, and
    # the weight bevel's emphasized sides carrying one extra.
    private def braille_run_masks(inner : Bool, light : Light) : {Int32, Int32, Int32, Int32}
      return braille_sparse_masks(inner) if @pattern.dashed? || @pattern.dotted?
      w2, v4 = Glyphs.braille_steps(@ratio)
      if @pattern.double?
        w2 = 2
        v4 = Math.max(v4, 2)
      end
      {braille_row_mask(inner, top: true, steps: (v4 + (weight_side?(Side::Top, light) ? 1 : 0)).clamp(1, 4)),
       braille_row_mask(inner, top: false, steps: (v4 + (weight_side?(Side::Bottom, light) ? 1 : 0)).clamp(1, 4)),
       braille_col_mask(inner, left: true, steps: (w2 + (weight_side?(Side::Left, light) ? 1 : 0)).clamp(1, 2)),
       braille_col_mask(inner, left: false, steps: (w2 + (weight_side?(Side::Right, light) ? 1 : 0)).clamp(1, 2))}
    end

    # The sparse-pattern run masks: hairline by definition (the thickness
    # rounds down to one dot-line) — dotted keeps every other dot; dashed
    # keeps dot pairs, expressible only down a column's four rows, so the
    # horizontal runs round dashed down to dotted.
    private def braille_sparse_masks(inner : Bool) : {Int32, Int32, Int32, Int32}
      tm = inner ? Glyphs::BRAILLE_DOTTED_ROW_BOTTOM : Glyphs::BRAILLE_DOTTED_ROW_TOP
      bm = inner ? Glyphs::BRAILLE_DOTTED_ROW_TOP : Glyphs::BRAILLE_DOTTED_ROW_BOTTOM
      if @pattern.dashed?
        lm = inner ? Glyphs::BRAILLE_DASHED_COL_RIGHT : Glyphs::BRAILLE_DASHED_COL_LEFT
        rm = inner ? Glyphs::BRAILLE_DASHED_COL_LEFT : Glyphs::BRAILLE_DASHED_COL_RIGHT
      else
        lm = inner ? Glyphs::BRAILLE_DOTTED_COL_RIGHT : Glyphs::BRAILLE_DOTTED_COL_LEFT
        rm = inner ? Glyphs::BRAILLE_DOTTED_COL_LEFT : Glyphs::BRAILLE_DOTTED_COL_RIGHT
      end
      {tm, bm, lm, rm}
    end

    # The four corner glyphs `{tl, tr, bl, br}` of an `Outer` block border:
    # the elbow whose arms sit closest to the two runs' thicknesses. The
    # eighth-L pieces when both runs are near an eighth (at `w8 == 2` the
    # 1-px side-arm pinch still beats every larger piece's bulge); the
    # Extended tier's thin-armed sextant elbows through the whole 3/8-6/8
    # midrange, where — with the runs re-quantized to thirds — the top joins
    # flush and the sides keep only a small chamfer; the three-quadrant
    # blocks for the non-Extended midrange; and the full block when the
    # sides are nearly solid (a corner reading as a deliberate solid block
    # beats the quadrant's bitten-side notch there).
    # A braille corner cell under its `Corner` treatment. *which* indexes
    # `{tl, tr, bl, br}`; the *hugged* cell corner is the same for the
    # outer anchoring and the diagonal one for inner (an inner TL corner's
    # ink sits at its cell's BR). `Rounded` clears the hugged corner's apex
    # dot from the union *mask* — at dot scale, knocking off the apex
    # genuinely reads as rounding; `Cut` replaces the mask with the two-dot
    # diagonal.
    private def braille_corner(style : Corner, mask : Int32, inner : Bool, which : Int32) : Char
      hug = inner ? 3 - which : which
      case style
      in .square?
        Glyphs.braille mask
      in .rounded?
        dot =
          case hug
          when 0 then Glyphs::BRAILLE_CORNER_DOT_TL
          when 1 then Glyphs::BRAILLE_CORNER_DOT_TR
          when 2 then Glyphs::BRAILLE_CORNER_DOT_BL
          else        Glyphs::BRAILLE_CORNER_DOT_BR
          end
        Glyphs.braille mask & ~dot
      in .cut?
        cut =
          case hug
          when 0 then Glyphs::BRAILLE_CUT_TL
          when 1 then Glyphs::BRAILLE_CUT_TR
          when 2 then Glyphs::BRAILLE_CUT_BL
          else        Glyphs::BRAILLE_CUT_BR
          end
        Glyphs.braille cut
      end
    end

    # The decorative corner beads an explicit `#corner_ratio` requests on an
    # outer block ring: solid elbows on the coarse ladder (eighth-L pieces →
    # three-quadrant blocks → the full block), deliberately skipping the
    # thin-armed sextant midrange — the bead is *meant* to out-weigh the
    # runs (the accidental-turned-deliberate `▛`-on-hairline look; see
    # plans/BORDERS.md § 3.3).
    private def outer_corner_beads(tier : Glyphs::Tier, corner_ratio : Float64)
      cw8, cv8 = Glyphs.block_eighths(corner_ratio)
      ci = cv8 <= 1 && cw8 <= 2 ? 0 : (cw8 <= 4 && cv8 <= 4 ? 3 : 7)
      {Glyphs.chars(Glyphs::SeqRole::BorderElbowTL, tier)[ci],
       Glyphs.chars(Glyphs::SeqRole::BorderElbowTR, tier)[ci],
       Glyphs.chars(Glyphs::SeqRole::BorderElbowBL, tier)[ci],
       Glyphs.chars(Glyphs::SeqRole::BorderElbowBR, tier)[ci]}
    end

    # Whether an `Outer` border's corners take the octant elbows: the range
    # they cover (arms half a cell wide, a quarter tall) — except the near-
    # hairline geometries, where the eighth-L pieces sit closer still.
    private def outer_octant_corners?(tier : Glyphs::Tier, w8 : Int32, v8 : Int32, octants : Bool) : Bool
      octants && tier.extended? && w8 <= 4 && v8 <= 2 && !(v8 <= 1 && w8 <= 2)
    end

    private def outer_block_corners(tier : Glyphs::Tier, w8 : Int32, v8 : Int32, octant_corners : Bool = false)
      if octant_corners
        return {Glyphs[Glyphs::Role::BorderOctantElbowTL, tier],
                Glyphs[Glyphs::Role::BorderOctantElbowTR, tier],
                Glyphs[Glyphs::Role::BorderOctantElbowBL, tier],
                Glyphs[Glyphs::Role::BorderOctantElbowBR, tier]}
      end
      if v8 <= 1 && w8 <= 2
        ci = 0
      elsif tier.extended? && w8 <= 6 && v8 <= 3
        return {Glyphs[Glyphs::Role::BorderThinElbowTL, tier],
                Glyphs[Glyphs::Role::BorderThinElbowTR, tier],
                Glyphs[Glyphs::Role::BorderThinElbowBL, tier],
                Glyphs[Glyphs::Role::BorderThinElbowBR, tier]}
      else
        ci = w8 <= 4 && v8 <= 4 ? 3 : 7
      end
      {Glyphs.chars(Glyphs::SeqRole::BorderElbowTL, tier)[ci],
       Glyphs.chars(Glyphs::SeqRole::BorderElbowTR, tier)[ci],
       Glyphs.chars(Glyphs::SeqRole::BorderElbowBL, tier)[ci],
       Glyphs.chars(Glyphs::SeqRole::BorderElbowBR, tier)[ci]}
    end

    # The four corner glyphs `{tl, tr, bl, br}` of an `Inner` block border,
    # whose ideal corner ink is just the small junction rectangle where the
    # two patterns meet. *fit* is the caller's `Glyphs.corner_fit` pick of the
    # least-spill treatment: a miter piece (sextant/quadrant), the horizontal
    # run (*t*/*b*) continued through the cell, or — for hairline rings,
    # whose patterns meet corner to corner — no glyph at all (`Glyphs::NONE`:
    # the render loop leaves the cell untouched). The open corner is a
    # deliberate pick over the closed alternatives, all of which spill worse
    # at hairline scale: the smallest miter bead (an octant) is several times
    # the pattern width, and an eighth-L's arms run the cell edges as spikes.
    private def inner_block_corners(fit : Symbol, tier : Glyphs::Tier, t : Char, b : Char)
      case fit
      when :strip
        {t, t, b, b}
      when :gap
        {Glyphs::NONE, Glyphs::NONE, Glyphs::NONE, Glyphs::NONE}
      when :octant
        # The octant miter, diagonal-mapped like the sextant one below.
        {Glyphs[Glyphs::Role::BorderOctantMiterBR, tier],
         Glyphs[Glyphs::Role::BorderOctantMiterBL, tier],
         Glyphs[Glyphs::Role::BorderOctantMiterTR, tier],
         Glyphs[Glyphs::Role::BorderOctantMiterTL, tier]}
      else
        # A miter piece, hugging the cell corner *diagonal* to the widget
        # corner it closes (an inner TL corner's ink sits at its cell's BR).
        # When the chooser settled on the quadrant while the tier is Extended
        # (the sextant didn't cover), resolve the role at the Unicode tier,
        # where its column holds the quadrant rendition.
        miter_tier = fit == :quadrant && tier.extended? ? Glyphs::Tier::Unicode : tier
        {Glyphs[Glyphs::Role::BorderMiterBR, miter_tier],
         Glyphs[Glyphs::Role::BorderMiterBL, miter_tier],
         Glyphs[Glyphs::Role::BorderMiterTR, miter_tier],
         Glyphs[Glyphs::Role::BorderMiterTL, miter_tier]}
      end
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
    # The media keep their own, distinct fall-back chains: a line border
    # resolves position → group → pattern-family glyph at *tier* (see
    # `#line_glyphs_with_overrides`), a block border position → group → ramp
    # step at `#ratio` (see `#block_glyphs_with_overrides`), a `Braille`
    # border position → group → dot mask at `#ratio` (see
    # `#braille_glyphs_with_overrides`), a `Fill` border
    # position → group → `#fill_char` (see `#top_char`/`#horizontal_char`/
    # `#top_left_char` …). All produce the same `NamedTuple` shape, so the
    # render call site stays monomorphic.
    # *cap_v*/*cap_h* say that this render dropped a pair of edges that did not
    # fit the box (`Widget#effective_insets`), leaving the perpendicular pair
    # standing alone: *cap_v* when the left/right edges survive without a
    # top/bottom to close them, *cap_h* for the transpose. A `Fill` border
    # paints colored cells and a block border edge-flush runs — neither implies
    # a shape the caps must repair, so both ignore them.
    # *light* feeds the weight bevel (`#relief_style`), which thickens the
    # lit or shaded sides' glyphs; under the default relief (`None`) it has
    # no effect on the octet.
    def glyph_octet(tier : Glyphs::Tier, cap_v = false, cap_h = false, octants : Bool = false,
                    light : Light = Light::DEFAULT)
      case @medium
      in .braille? then braille_glyphs_with_overrides(tier, light)
      in .block?   then block_glyphs_with_overrides(tier, octants, light)
      in .line?    then line_glyphs_with_overrides(tier, cap_v, cap_h, light)
      in .fill?
        {tl: top_left_char, tr: top_right_char, bl: bottom_left_char, br: bottom_right_char,
         t: top_char, b: bottom_char, l: left_char, r: right_char}
      end
    end

    # Whether the band cell at *depth* (0 = the outermost cell of its side)
    # in a side *width* cells thick carries the border's rule, or is band
    # ground. At 1-cell widths every band cell does — the classic geometry.
    # For thicker bands the alignment axis decides where the rule sits
    # (plans/BORDERS.md § phase 6): `Center` repeats the rule through the
    # whole band (the pre-axes behavior), `Outer` draws it only along the
    # band's rim ring, `Inner` only along the ring hugging the content. A
    # block-medium `Double` pattern rules both the rim and content rings —
    # the two-ring reading of the pattern that a single cell can't express.
    def band_rule?(depth : Int32, width : Int32) : Bool
      return true if width <= 1
      if @medium.block? && @pattern.double?
        return depth == 0 || depth == width - 1
      end
      case @align
      in .center? then true
      in .outer?  then depth == 0
      in .inner?  then depth == width - 1
      end
    end

    # Whether a thick band's ruled ring is *smaller than the box* (`Inner`
    # alignment): its runs then must not cross the perpendicular bands'
    # outward cells — a cell of the left band short of the ring's corner
    # column is ground, not a piece of the top run. The rim-hugging rings
    # (`Outer`/`Center`, and the block `Double` pair, whose outer ring spans
    # the full box) pass over the whole band width. Meaningless (and never
    # consulted) at 1-cell widths, where every band cell is on the ring.
    def inner_band_ring? : Bool
      @align.inner? && !(@medium.block? && @pattern.double?)
    end

    # Whether a dashed/dotted *block*-medium run leaves a gap at run cell
    # *offset* (cells from the box's own edge, so opposite runs stay in
    # phase): dotted alternates ink and ground cells, dashed runs two ink
    # cells to one ground. The other media draw their dashes sub-cell
    # (line: the `┄`/`┈` glyph families; braille: the sparse dot masks), so
    # they never gap whole cells; corners are always drawn.
    def run_gap?(offset : Int32) : Bool
      return false unless @medium.block?
      case @pattern
      in .dotted?          then offset.odd?
      in .dashed?          then offset % 3 == 2
      in .solid?, .double? then false
      end
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
        new value, value, value, value
      in Tuple(Int32, Int32), Tuple(Int32, Int32, Int32, Int32)
        # CSS shorthand orders: `{vertical, horizontal}` / `{top, right,
        # bottom, left}`.
        SidedGeometry.from_tuple_arms value
      end
    end

    def initialize(
      type : BorderType? = nil,
      bg = nil,
      fg = nil,
      @left = @left,
      @top = @top,
      @right = @right,
      @bottom = @bottom,
      ratio : (Float64 | Symbol)? = nil,
      pattern : (Pattern | Symbol)? = nil,
      align : (Align | Symbol)? = nil,
      corners : (Corners | Corner | Symbol)? = nil,
      corner_ratio : (Float64 | Symbol)? = nil,
      relief : (Relief | Symbol)? = nil,
      relief_style : (ReliefStyle | Symbol)? = nil,
    )
      # Route through setters so a native int or a `"#rrggbb"`/named string
      # both resolve to the native int form, a `ratio` given as a named
      # preset (`:thin`, `:half`, …) to its fraction, and enum axes given as
      # symbols to their members. The `type` preset fans out over the axes
      # first, so explicit axis arguments override it.
      self.type = type if type
      case pattern
      in Pattern, Symbol then self.pattern = pattern
      in Nil
      end
      case align
      in Align, Symbol then self.align = align
      in Nil
      end
      case corners
      in Corners, Corner, Symbol then self.corners = corners
      in Nil
      end
      case relief
      in Relief then self.relief = relief
      in Symbol then self.relief = relief
      in Nil
      end
      case relief_style
      in ReliefStyle then self.relief_style = relief_style
      in Symbol      then self.relief_style = relief_style
      in Nil
      end
      self.bg = bg unless bg.nil?
      self.fg = fg unless fg.nil?
      case ratio
      in Float64 then self.ratio = ratio
      in Symbol  then self.ratio = ratio
      in Nil
      end
      case corner_ratio
      in Float64 then self.corner_ratio = corner_ratio
      in Symbol  then self.corner_ratio = corner_ratio
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
