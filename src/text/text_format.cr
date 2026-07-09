module Crysterm
  # Base of the text-format family used by the `TextDocument` framework,
  # mirroring Qt's QTextFormat hierarchy (see TEXTEDIT.md §2/§3).
  #
  # Formats are *immutable*: every derivation (`#merge`, setters would be
  # copies) returns a new object, so fragments, undo snapshots and pending
  # cursor formats can share references freely. Classes (not structs) because
  # Qt's hierarchy has concrete inheritance (`QTextTableFormat <
  # QTextFrameFormat`, `QTextImageFormat < QTextCharFormat`), which Crystal
  # structs don't allow.
  abstract class TextFormat
  end

  # Character-level format (Qt `QTextCharFormat`), reduced to the
  # SGR-expressible set per TEXTEDIT.md §3. Colors are stored like `Style`'s:
  # native `0xRRGGBB` ints (`-1` = terminal default, `nil` = unset), with
  # `"#rrggbb"`/named strings accepted and parsed via `Colors.convert_cached`.
  #
  # Alongside the attribute *values* the format carries `attr_mask`: which
  # boolean attributes were explicitly specified. That is Qt's property-
  # presence semantics — it lets a format act as a *patch* in `#merge`, so
  # `TextCharFormat.new(bold: false)` can un-bold a selection while leaving
  # unspecified attributes alone. The mask is meaningless for stored/rendered
  # formats; visual identity is `#same_appearance?`, which ignores it.
  class TextCharFormat < TextFormat
    # Boolean attributes. All but `Code` are SGR-expressible; `Code` is a
    # *semantic* marker (Qt `fontFixedPitch`) — verbatim/monospace text — that
    # the interchange formats (markdown backticks, HTML `<code>`) need to
    # round-trip. It renders only through whatever colors the importer paired
    # it with, like `anchor_href` (the other non-SGR semantic property).
    @[Flags]
    enum Attr
      Bold
      Italic
      Underline
      Strike
      Inverse
      Dim
      Blink
      Code
    end

    # Attribute values (only bits within `attr_mask` are meaningful as a patch;
    # all bits are meaningful when the format is stored on a fragment).
    getter attributes : Attr

    # Which boolean attributes were explicitly specified (Qt property presence).
    getter attr_mask : Attr

    # Foreground color (`0xRRGGBB`, `-1` = terminal default, `nil` = unset).
    getter fg : Int32?

    # Background color; same convention as `fg`.
    getter bg : Int32?

    # Hyperlink target (Qt `anchorHref`); rendered via OSC 8 where supported.
    getter anchor_href : String?

    # Shared all-defaults instance, so empty formats don't allocate per use.
    class_getter default : TextCharFormat { new }

    def initialize(
      *,
      bold : Bool? = nil,
      italic : Bool? = nil,
      underline : Bool? = nil,
      strike : Bool? = nil,
      inverse : Bool? = nil,
      dim : Bool? = nil,
      blink : Bool? = nil,
      code : Bool? = nil,
      fg : Int32 | String | Nil = nil,
      bg : Int32 | String | Nil = nil,
      anchor_href : String? = nil,
    )
      attrs = Attr::None
      mask = Attr::None
      {% for a in %w(bold italic underline strike inverse dim blink code) %}
        unless {{a.id}}.nil?
          mask |= Attr::{{a.camelcase.id}}
          attrs |= Attr::{{a.camelcase.id}} if {{a.id}}
        end
      {% end %}
      @attributes = attrs
      @attr_mask = mask
      @fg = fg.is_a?(String) ? Colors.convert_cached(fg) : fg
      @bg = bg.is_a?(String) ? Colors.convert_cached(bg) : bg
      @anchor_href = anchor_href
    end

    protected def initialize(@attributes, @attr_mask, @fg, @bg, @anchor_href)
    end

    {% for a in %w(bold italic underline strike inverse dim blink code) %}
      def {{a.id}}? : Bool
        @attributes.{{a.id}}?
      end
    {% end %}

    def anchor? : Bool
      !@anchor_href.nil?
    end

    # Returns this format overridden by `patch` (Qt `mergeCharFormat`
    # semantics): boolean attributes copy only the bits `patch` explicitly
    # specifies; colors/anchor copy when non-nil. Un-setting a color or anchor
    # through a merge is not expressible (`nil` means "unspecified") — use
    # `TextCursor#set_char_format` (replace) for that.
    def merge(patch : TextCharFormat) : TextCharFormat
      TextCharFormat.new(
        (@attributes & ~patch.attr_mask) | (patch.attributes & patch.attr_mask),
        @attr_mask | patch.attr_mask,
        patch.fg || @fg,
        patch.bg || @bg,
        patch.anchor_href || @anchor_href,
      )
    end

    # Visual identity — what fragment normalization merges on. Ignores
    # `attr_mask` (patch bookkeeping), unlike `==`.
    def same_appearance?(other : TextCharFormat) : Bool
      @attributes == other.attributes && @fg == other.fg &&
        @bg == other.bg && @anchor_href == other.anchor_href
    end

    def_equals_and_hash @attributes, @attr_mask, @fg, @bg, @anchor_href
  end

  # Paragraph-level format (Qt `QTextBlockFormat`). All properties are
  # tri-state (`nil` = unspecified) so a format can act as a merge patch;
  # readers get the effective default. Margins are whole blank rows — the
  # cell grid has no sub-row spacing.
  class TextBlockFormat < TextFormat
    # Horizontal alignment; `nil` = default (left).
    getter alignment : Tput::AlignFlag?

    # Block background color; same convention as `TextCharFormat#bg`.
    getter bg : Int32?

    # Shared all-defaults instance.
    class_getter default : TextBlockFormat { new }

    @indent : Int32?
    @top_margin : Int32?
    @bottom_margin : Int32?
    @heading_level : Int32?
    @non_breakable : Bool?

    def initialize(
      *,
      @alignment : Tput::AlignFlag? = nil,
      indent : Int32? = nil,
      top_margin : Int32? = nil,
      bottom_margin : Int32? = nil,
      bg : Int32 | String | Nil = nil,
      heading_level : Int32? = nil,
      non_breakable : Bool? = nil,
    )
      @indent = indent
      @top_margin = top_margin
      @bottom_margin = bottom_margin
      @bg = bg.is_a?(String) ? Colors.convert_cached(bg) : bg
      @heading_level = heading_level
      @non_breakable = non_breakable
    end

    # Indentation in cells (levels are the widget's concern).
    def indent : Int32
      @indent || 0
    end

    # Blank rows above the block.
    def top_margin : Int32
      @top_margin || 0
    end

    # Blank rows below the block.
    def bottom_margin : Int32
      @bottom_margin || 0
    end

    # Heading level, 0 = body text (Qt `headingLevel`). The terminal
    # approximation of font sizes — rendering maps levels to bold/color.
    def heading_level : Int32
      @heading_level || 0
    end

    def heading? : Bool
      heading_level > 0
    end

    # Whether the block resists being broken across pages/frames. Kept for Qt
    # parity; unused until frames render.
    def non_breakable? : Bool
      @non_breakable || false
    end

    # Returns this format overridden by `patch`: properties `patch` specifies
    # (non-nil) win, the rest are kept.
    def merge(patch : TextBlockFormat) : TextBlockFormat
      TextBlockFormat.new(
        alignment: patch.alignment || @alignment,
        indent: patch.@indent || @indent,
        top_margin: patch.@top_margin || @top_margin,
        bottom_margin: patch.@bottom_margin || @bottom_margin,
        bg: patch.bg || @bg,
        heading_level: patch.@heading_level || @heading_level,
        non_breakable: patch.@non_breakable || @non_breakable,
      )
    end

    def_equals_and_hash @alignment, @indent, @top_margin, @bottom_margin, @bg, @heading_level, @non_breakable
  end

  # List format (Qt `QTextListFormat`). Consumed by `TextList` in Phase 4;
  # defined now so the format hierarchy is complete (TEXTEDIT.md §2).
  class TextListFormat < TextFormat
    enum Style
      Disc
      Circle
      Square
      Decimal
      LowerAlpha
      UpperAlpha
      LowerRoman
      UpperRoman
    end

    getter style : Style
    getter indent : Int32

    def initialize(*, @style : Style = Style::Disc, @indent : Int32 = 1)
    end

    def_equals_and_hash @style, @indent
  end

  # Frame format (Qt `QTextFrameFormat`). Margins/border in cells; border
  # renders as box-drawing when frames render (Phase 4).
  class TextFrameFormat < TextFormat
    getter margin : Int32
    getter? border : Bool

    class_getter default : TextFrameFormat { new }

    def initialize(*, @margin : Int32 = 0, @border : Bool = false)
    end
  end

  # Table format (Qt `QTextTableFormat < QTextFrameFormat`). Phase 4.
  class TextTableFormat < TextFrameFormat
    getter columns : Int32

    def initialize(*, @columns : Int32 = 1, margin : Int32 = 0, border : Bool = true)
      super(margin: margin, border: border)
    end
  end

  # Inline image (Qt `QTextImageFormat < QTextCharFormat`). Phase 4+ —
  # read-only embedded blocks via the media/sixel path, if at all.
  class TextImageFormat < TextCharFormat
    # Image source (path or URL).
    getter name : String

    # Desired size in cells; `nil` = natural.
    getter width : Int32?
    getter height : Int32?

    def initialize(*, @name : String = "", @width : Int32? = nil, @height : Int32? = nil)
      super()
    end
  end

  # Table cell format (Qt `QTextTableCellFormat < QTextCharFormat`). Phase 4.
  class TextTableCellFormat < TextCharFormat
    getter row_span : Int32
    getter column_span : Int32

    def initialize(*, @row_span : Int32 = 1, @column_span : Int32 = 1)
      super()
    end
  end
end
