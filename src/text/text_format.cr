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

    # The list this block belongs to, or nil. List membership is carried by
    # *instance identity* of the shared `TextListFormat` (all items of one
    # list reference the same object; see `TextList`) — the stand-in for Qt's
    # `objectIndex` that survives detached blocks (clipboard fragments,
    # importer output) with no document-side registry. Block splits/merges and
    # undo snapshots copy the reference, so pressing Enter in a list item
    # continues the list and undo restores membership, as in Qt.
    getter list_format : TextListFormat?

    # The table this block is a rendered row of, or nil — same shared-
    # instance identity convention as `list_format` (see `TextTable`).
    getter table_format : TextTableFormat?

    # The block's frame *path*: the chain of child frames containing it,
    # outermost first — nil/empty means the block sits directly in the
    # document's root frame. Same shared-instance identity convention as
    # `list_format`: all blocks of one frame reference the same
    # `TextFrameFormat` instance (see `TextFrame`), so splits/merges, undo
    # and clipboard fragments preserve frame membership for free.
    getter frame_formats : Array(TextFrameFormat)?

    # Shared all-defaults instance.
    class_getter default : TextBlockFormat { new }

    @indent : Int32?
    @top_margin : Int32?
    @bottom_margin : Int32?
    @heading_level : Int32?
    @non_breakable : Bool?
    @quote_level : Int32?
    @horizontal_rule : Bool?
    # Whether this block is a *checked* item of a `Checkbox`-style list.
    # `nil`/`false` = unchecked; only meaningful when `list_format`'s style
    # is `Checkbox`. Kept per-block because the list format is shared by all
    # items (the stand-in for Qt's per-item state on a shared list object).
    @checked : Bool?

    def initialize(
      *,
      @alignment : Tput::AlignFlag? = nil,
      indent : Int32? = nil,
      top_margin : Int32? = nil,
      bottom_margin : Int32? = nil,
      bg : Int32 | String | Nil = nil,
      heading_level : Int32? = nil,
      non_breakable : Bool? = nil,
      quote_level : Int32? = nil,
      horizontal_rule : Bool? = nil,
      checked : Bool? = nil,
      list_format : TextListFormat? = nil,
      table_format : TextTableFormat? = nil,
      frame_formats : Array(TextFrameFormat)? = nil,
    )
      @indent = indent
      @top_margin = top_margin
      @bottom_margin = bottom_margin
      @bg = bg.is_a?(String) ? Colors.convert_cached(bg) : bg
      @heading_level = heading_level
      @non_breakable = non_breakable
      @quote_level = quote_level
      @horizontal_rule = horizontal_rule
      @checked = checked
      @list_format = list_format
      @table_format = table_format
      @frame_formats = frame_formats
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

    # Blockquote nesting depth, 0 = not quoted (Qt's `BlockQuoteLevel`
    # property). Renders as one bar-glyph column per level.
    def quote_level : Int32
      @quote_level || 0
    end

    # Whether the block renders as a horizontal rule: a full-width line of
    # rule glyphs regardless of its (conventionally empty) text — the
    # terminal analog of Qt's `BlockTrailingHorizontalRulerWidth`.
    def horizontal_rule? : Bool
      @horizontal_rule || false
    end

    # Whether a `Checkbox`-style list item is checked (Qt task-item state).
    def checked? : Bool
      @checked || false
    end

    # Returns this format overridden by `patch`: properties `patch` specifies
    # (non-nil) win, the rest are kept. The frame path replaces wholesale (a
    # patch with `frame_formats` moves the block to that exact nesting).
    def merge(patch : TextBlockFormat) : TextBlockFormat
      TextBlockFormat.new(
        alignment: patch.alignment || @alignment,
        indent: patch.@indent || @indent,
        top_margin: patch.@top_margin || @top_margin,
        bottom_margin: patch.@bottom_margin || @bottom_margin,
        bg: patch.bg || @bg,
        heading_level: patch.@heading_level || @heading_level,
        non_breakable: patch.@non_breakable || @non_breakable,
        quote_level: patch.@quote_level || @quote_level,
        horizontal_rule: patch.@horizontal_rule || @horizontal_rule,
        checked: patch.@checked || @checked,
        list_format: patch.list_format || @list_format,
        table_format: patch.table_format || @table_format,
        frame_formats: patch.frame_formats || @frame_formats,
      )
    end

    # A copy with the list reference replaced (or `nil` — cleared). `#merge`
    # can't express clearing (nil = unspecified), so `TextList#add/#remove`
    # rewrite the whole format through this.
    def with_list_format(lf : TextListFormat?) : TextBlockFormat
      TextBlockFormat.new(
        alignment: @alignment, indent: @indent, top_margin: @top_margin,
        bottom_margin: @bottom_margin, bg: @bg, heading_level: @heading_level,
        non_breakable: @non_breakable, quote_level: @quote_level,
        horizontal_rule: @horizontal_rule, checked: @checked, list_format: lf,
        table_format: @table_format, frame_formats: @frame_formats)
    end

    # A copy with the checkbox state replaced (or cleared with `nil`). Toggles
    # a `Checkbox`-style item; `#merge` can't set `false` over a stored value
    # (nil = unspecified), same as `#with_list_format`.
    def with_checked(checked : Bool?) : TextBlockFormat
      TextBlockFormat.new(
        alignment: @alignment, indent: @indent, top_margin: @top_margin,
        bottom_margin: @bottom_margin, bg: @bg, heading_level: @heading_level,
        non_breakable: @non_breakable, quote_level: @quote_level,
        horizontal_rule: @horizontal_rule, checked: checked, list_format: @list_format,
        table_format: @table_format, frame_formats: @frame_formats)
    end

    # A copy with the frame path replaced (or `nil` — moved to the root
    # frame). `#merge` can't express clearing, same as `#with_list_format`.
    def with_frame_formats(ff : Array(TextFrameFormat)?) : TextBlockFormat
      TextBlockFormat.new(
        alignment: @alignment, indent: @indent, top_margin: @top_margin,
        bottom_margin: @bottom_margin, bg: @bg, heading_level: @heading_level,
        non_breakable: @non_breakable, quote_level: @quote_level,
        horizontal_rule: @horizontal_rule, checked: @checked, list_format: @list_format,
        table_format: @table_format, frame_formats: ff)
    end

    def_equals_and_hash @alignment, @indent, @top_margin, @bottom_margin, @bg, @heading_level, @non_breakable, @quote_level, @horizontal_rule, @checked, @list_format, @table_format, @frame_formats
  end

  # List format (Qt `QTextListFormat`): marker style, nesting depth, numbering
  # start and prefix/suffix. One *instance* is shared by all member blocks of
  # a list — instance identity IS list identity (see
  # `TextBlockFormat#list_format`) — so treat instances as one-per-list, not
  # as interchangeable values.
  class TextListFormat < TextFormat
    enum Style
      Disc
      Circle
      Square
      # A GFM task-list marker (`[x]`/`[ ]`); the per-item checked state
      # lives on the member block (`TextBlockFormat#checked?`), since the
      # format instance is shared by every item.
      Checkbox
      Decimal
      LowerAlpha
      UpperAlpha
      LowerRoman
      UpperRoman

      def numbered? : Bool
        self >= Decimal
      end
    end

    getter style : Style

    # Nesting depth, 1 = top level (Qt convention). Rendering indents
    # `(indent - 1) * 2` cells.
    getter indent : Int32

    # First item's number, for `numbered?` styles (Qt 6 `start`).
    getter start : Int32

    # Text around a `numbered?` marker: `"1. "`, `"(a) "`, … (Qt
    # `numberPrefix`/`numberSuffix`; the trailing space is added by `#marker`).
    getter number_prefix : String
    getter number_suffix : String

    def initialize(
      *,
      @style : Style = Style::Disc,
      @indent : Int32 = 1,
      @start : Int32 = 1,
      @number_prefix : String = "",
      @number_suffix : String = ".",
    )
    end

    # The rendered marker of 0-based item *item* under this format, including
    # the separating trailing space: `"• "`, `"3. "`, `"c) "`, `"[x] "`…
    # `checked` selects the mark of a `Checkbox`-style item (its state lives
    # on the member block, not here); it is ignored by the other styles.
    def marker(item : Int32, tier : Glyphs::Tier = Glyphs::Tier::Unicode, checked : Bool = false) : String
      case style
      when .disc?   then "#{Glyphs[Glyphs::Role::IconBullet, tier]} "
      when .circle? then "#{Glyphs[Glyphs::Role::IconCircle, tier]} "
      when .square? then "#{Glyphs[Glyphs::Role::IconSquareFilled, tier]} "
      when .checkbox?
        # Composed like the `CheckBox` widget's marker: `[x]`/`[ ]` in the
        # ascii tier, `[✓]`/`[ ]` in unicode — all single-width cells.
        mark = checked ? Glyphs[Glyphs::Role::CheckboxChecked, tier] : Glyphs[Glyphs::Role::CheckboxUnchecked, tier]
        "#{Glyphs[Glyphs::Role::CheckboxOpen, tier]}#{mark}#{Glyphs[Glyphs::Role::CheckboxClose, tier]} "
      else
        n = @start + item
        "#{@number_prefix}#{number_text(n)}#{@number_suffix} "
      end
    end

    private def number_text(n : Int32) : String
      case style
      when .lower_alpha? then TextListFormat.alpha(n)
      when .upper_alpha? then TextListFormat.alpha(n).upcase
      when .lower_roman? then TextListFormat.roman(n)
      when .upper_roman? then TextListFormat.roman(n).upcase
      else                    n.to_s
      end
    end

    # 1 → "a", 26 → "z", 27 → "aa" (bijective base-26); non-positive numbers
    # fall back to decimal.
    protected def self.alpha(n : Int32) : String
      return n.to_s if n < 1
      s = [] of Char
      while n > 0
        n -= 1
        s << ('a' + n % 26)
        n //= 26
      end
      s.reverse.join
    end

    # 1 → "i", 4 → "iv", 1990 → "mcmxc"; out-of-range (< 1 or > 3999) falls
    # back to decimal.
    protected def self.roman(n : Int32) : String
      return n.to_s if n < 1 || n > 3999
      pairs = { {1000, "m"}, {900, "cm"}, {500, "d"}, {400, "cd"},
               {100, "c"}, {90, "xc"}, {50, "l"}, {40, "xl"},
               {10, "x"}, {9, "ix"}, {5, "v"}, {4, "iv"}, {1, "i"} }
      String.build do |io|
        pairs.each do |(v, r)|
          while n >= v
            io << r
            n -= v
          end
        end
      end
    end

    def_equals_and_hash @style, @indent, @start, @number_prefix, @number_suffix
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

  # Table format (Qt `QTextTableFormat < QTextFrameFormat`). One *instance*
  # per table — instance identity is table identity, referenced from every
  # member block's `TextBlockFormat#table_format` (the `TextListFormat`
  # convention; see `TextTable`).
  class TextTableFormat < TextFrameFormat
    getter columns : Int32

    # Per-column horizontal alignment (GFM `:---:`); `nil`/missing = left.
    getter alignments : Array(Tput::AlignFlag)?

    def initialize(*, @columns : Int32 = 1, margin : Int32 = 0, border : Bool = true, @alignments : Array(Tput::AlignFlag)? = nil)
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
