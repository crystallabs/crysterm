module Crysterm
  # Base of the text-format family, mirroring Qt's QTextFormat hierarchy.
  #
  # Formats are *immutable*: every derivation returns a new object, so
  # fragments, undo snapshots and pending cursor formats can share references
  # freely. Classes rather than structs, because Qt's hierarchy uses concrete
  # inheritance (`QTextTableFormat < QTextFrameFormat`, `QTextImageFormat <
  # QTextCharFormat`) and Crystal structs don't allow it.
  abstract class TextFormat
  end

  # Character-level format (Qt `QTextCharFormat`), reduced to the
  # SGR-expressible set. Colors are stored like `Style`'s: native `0xRRGGBB`
  # ints (`-1` = terminal default, `nil` = unset), with `"#rrggbb"`/named
  # strings accepted and parsed.
  #
  # Alongside the attribute *values* the format carries `attr_mask`: which
  # boolean attributes were explicitly specified (Qt's property-presence
  # semantics). It lets a format act as a *patch* in `#merge`, so
  # `TextCharFormat.new(bold: false)` can un-bold a selection while leaving
  # unspecified attributes alone. The mask is meaningless for stored/rendered
  # formats; visual identity is `#same_appearance?`, which ignores it.
  class TextCharFormat < TextFormat
    # Boolean attributes. All but `Code` and `Rule` are SGR-expressible.
    # `Code` is a *semantic* marker (Qt `fontFixedPitch`) for verbatim/
    # monospace text that the interchange formats (markdown backticks, HTML
    # `<code>`) round-trip; `Rule` marks structural line-drawing text (table
    # borders) that is content, not prose. Neither has a cell flag: a view
    # colors them — like `anchor_href`, `dim` and a heading block — from its
    # own style's content slots (`Style#code`, `#rule`, `#link`, `#muted`,
    # `#heading`), so the document carries meaning and the stylesheet decides
    # the look.
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
      Rule
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

    # The text's tool tip (Qt `toolTip`): what the importers keep of a
    # Markdown link's or image's title (`[x](u "title")`, `![a](s "title")`)
    # and of an HTML element's `title` attribute, as Qt's importers do, and
    # what the exporters write back as that title. Text, not appearance:
    # a view paints it as the text around it.
    getter tool_tip : String?

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
      rule : Bool? = nil,
      fg : Int32 | String? = nil,
      bg : Int32 | String? = nil,
      anchor_href : String? = nil,
      tool_tip : String? = nil,
    )
      attrs = Attr::None
      mask = Attr::None
      {% for a in %w[bold italic underline strike inverse dim blink code rule] %}
        unless {{ a.id }}.nil?
          mask |= Attr::{{ a.camelcase.id }}
          attrs |= Attr::{{ a.camelcase.id }} if {{ a.id }}
        end
      {% end %}
      @attributes = attrs
      @attr_mask = mask
      @fg = Colors.to_native fg
      @bg = Colors.to_native bg
      @anchor_href = anchor_href
      @tool_tip = tool_tip
    end

    protected def initialize(@attributes, @attr_mask, @fg, @bg, @anchor_href, @tool_tip)
    end

    {% for a in %w[bold italic underline strike inverse dim blink code rule] %}
      def {{ a.id }}? : Bool
        @attributes.{{ a.id }}?
      end
    {% end %}

    def anchor? : Bool
      !@anchor_href.nil?
    end

    # Returns this format overridden by `patch` (Qt `mergeCharFormat`
    # semantics): boolean attributes copy only the bits `patch` explicitly
    # specifies; colors/anchor/tool tip copy when non-nil. Un-setting a color or anchor
    # through a merge is not expressible (`nil` means "unspecified") — use
    # `TextCursor#set_char_format` (replace) for that.
    def merge(patch : TextCharFormat) : TextCharFormat
      TextCharFormat.new(
        (@attributes & ~patch.attr_mask) | (patch.attributes & patch.attr_mask),
        @attr_mask | patch.attr_mask,
        patch.fg || @fg,
        patch.bg || @bg,
        patch.anchor_href || @anchor_href,
        patch.tool_tip || @tool_tip,
      )
    end

    # Visual identity — what fragment normalization merges on. Unlike `==`,
    # ignores `attr_mask`, which is patch bookkeeping. The tool tip counts,
    # as the anchor does: runs with different titles stay apart, so each
    # keeps its own.
    def same_appearance?(other : TextCharFormat) : Bool
      @attributes == other.attributes && @fg == other.fg &&
        @bg == other.bg && @anchor_href == other.anchor_href &&
        @tool_tip == other.tool_tip
    end

    # Applies this format over a packed cell-attr word (`::Crysterm::Attr` —
    # the enum above shadows that name here) with unconditional *set*
    # semantics: every true boolean turns its flag on (anchors render
    # underlined); colors apply when set (`-1` maps to the terminal default).
    # `dim` has no packed flag in the cell model and `code`/`rule` are
    # semantic-only; none of the three is rendered here (a `TextEdit` colors
    # them from its style). The mask is ignored — for mask-aware Qt patch
    # semantics use `#merge_onto`. Protected: the packed cell-attr word is
    # the render pipeline's private encoding, not user API.
    protected def apply_to_attr(attr : Int64) : Int64
      flags = ::Crysterm::Attr.flags(attr)
      flags |= ::Crysterm::Attr::BOLD if bold?
      flags |= ::Crysterm::Attr::ITALIC if italic?
      flags |= ::Crysterm::Attr::UNDERLINE if underline? || anchor?
      flags |= ::Crysterm::Attr::STRIKE if strike?
      flags |= ::Crysterm::Attr::REVERSE if inverse?
      flags |= ::Crysterm::Attr::BLINK if blink?
      fg = (c = @fg) ? ::Crysterm::Attr.pack_color(c) : ::Crysterm::Attr.fg(attr)
      bg = (c = @bg) ? ::Crysterm::Attr.pack_color(c) : ::Crysterm::Attr.bg(attr)
      ::Crysterm::Attr.pack(flags, fg, bg)
    end

    # Applies this format as a *patch* over a packed cell-attr word (Qt merge
    # semantics: only attributes the format's mask specifies change — set or
    # cleared per their value; colors apply when set). Protected like
    # `#apply_to_attr`.
    protected def merge_onto(attr : Int64) : Int64
      flags = ::Crysterm::Attr.flags(attr)
      {% for a, flag in {bold: "BOLD", italic: "ITALIC", underline: "UNDERLINE", strike: "STRIKE", inverse: "REVERSE", blink: "BLINK"} %}
        if attr_mask.{{ a.id }}?
          if {{ a.id }}?
            flags |= ::Crysterm::Attr::{{ flag.id }}
          else
            flags &= ~::Crysterm::Attr::{{ flag.id }}.to_i64
          end
        end
      {% end %}
      fg = (c = @fg) ? ::Crysterm::Attr.pack_color(c) : ::Crysterm::Attr.fg(attr)
      bg = (c = @bg) ? ::Crysterm::Attr.pack_color(c) : ::Crysterm::Attr.bg(attr)
      ::Crysterm::Attr.pack(flags, fg, bg)
    end

    def_equals_and_hash @attributes, @attr_mask, @fg, @bg, @anchor_href, @tool_tip
  end

  # Paragraph-level format (Qt `QTextBlockFormat`). All properties are
  # tri-state (`nil` = unspecified) so a format can act as a merge patch;
  # readers get the effective default. Margins are whole blank rows — the
  # cell grid has no sub-row spacing.
  class TextBlockFormat < TextFormat
    # GFM alert kind (a blockquote whose first line is `[!NOTE]`/`[!TIP]`/
    # `[!IMPORTANT]`/`[!WARNING]`/`[!CAUTION]`, the github.com blockquote
    # extension). Carried alongside `quote_level` — an alert block is always
    # also quoted — so painting can pick a distinct color/title chip per kind
    # while the quote bar/indent machinery stays untouched.
    enum AlertKind
      Note
      Tip
      Important
      Warning
      Caution

      # The alert's title as github.com writes it (`"Note"`, `"Tip"`, …):
      # the text of its `markdown-alert-title` line in HTML.
      def title : String
        to_s
      end

      # The icon of the alert's title chip (`#marker`) — the "distinct per
      # kind" look GitHub's alert admonitions use, from the `Glyphs::Role`
      # icon palette.
      def icon_role : Glyphs::Role
        case self
        in .note?      then Glyphs::Role::IconInfo
        in .tip?       then Glyphs::Role::IconLightning
        in .important? then Glyphs::Role::IconCritical
        in .warning?   then Glyphs::Role::IconWarning
        in .caution?   then Glyphs::Role::IconWarningSign
        end
      end

      # The title chip a view paints at an alert block's text start on its
      # first row, `"ℹ NOTE "` and so on: the icon at *tier*, the title in
      # capitals and a space. It takes the place a list item's marker
      # (`TextListFormat#marker`) has, so a text rendering of the document
      # can show it where the view does.
      def marker(tier : Glyphs::Tier = Glyphs::Tier::Unicode) : String
        "#{Glyphs[icon_role, tier]} #{title.upcase} "
      end
    end

    # Horizontal alignment; `nil` = default (left).
    getter alignment : Tput::AlignFlag?

    # Block background color; same convention as `TextCharFormat#bg`.
    getter bg : Int32?

    # The list this block belongs to, or nil. Membership is carried by
    # *instance identity* of the shared `TextListFormat` — all items of one
    # list reference the same object — standing in for Qt's `objectIndex` so
    # that detached blocks (clipboard fragments, importer output) need no
    # document-side registry. Splits/merges and undo snapshots copy the
    # reference, so Enter in a list item continues the list and undo restores
    # membership.
    getter list_format : TextListFormat?

    # The table this block is a rendered row of, or nil — same shared-instance
    # identity convention as `list_format`.
    getter table_format : TextTableFormat?

    # The block's frame *path*: the chain of child frames containing it,
    # outermost first; nil/empty means the block sits directly in the root
    # frame. Same shared-instance identity convention as `list_format`.
    getter frame_formats : Array(TextFrameFormat)?

    # The GFM alert kind this block belongs to, or `nil` for an ordinary
    # block/quote. See `AlertKind`.
    getter alert_kind : AlertKind?

    # The info string of the fenced code block this block is a line of (Qt
    # `BlockCodeLanguage`): `""` for a fence without one, `nil` for a block
    # that is not code. Presence is what makes a code block (`#code_block?`);
    # a view paints it on its code background, and the exporters fence it.
    getter code_language : String?

    # The image this block *is* — a Markdown paragraph holding nothing but
    # `![alt](src)` (`TextImageFormat`) — or `nil` for a text block. The
    # block's text is the picture glyph and the alt text, so the block has
    # positions like any other; a view that draws images reserves rows
    # above the text for the picture (`Widget::TextEdit#images_enabled?`),
    # and the Markdown exporter writes the image back. Qt keeps an image in
    # a fragment's char format; on a cell grid a picture is a block of its
    # own rows, so it rides on the block.
    getter image : TextImageFormat?

    # Shared all-defaults instance.
    class_getter default : TextBlockFormat { new }

    @indent : Int32?
    @top_margin : Int32?
    @bottom_margin : Int32?
    @heading_level : Int32?
    @non_breakable : Bool?
    @quote_level : Int32?
    @horizontal_rule : Bool?
    # Whether this block is a *checked* task item (see `#task?`).
    # `nil`/`false` = unchecked; only meaningful on a task item. Per-block
    # because the list format is shared by all items.
    @checked : Bool?
    # Whether this list item carries a task box (Qt's block `marker`): `nil`
    # follows the list — a `Checkbox`-style list's items do, other lists'
    # don't — while `true` boxes an item of any other list (GFM's
    # `1. [ ] a`) and `false` leaves an item of a `Checkbox` list a plain one
    # (`- c` among `- [ ] a` items).
    @task : Bool?

    def initialize(
      *,
      @alignment : Tput::AlignFlag? = nil,
      indent : Int32? = nil,
      top_margin : Int32? = nil,
      bottom_margin : Int32? = nil,
      bg : Int32 | String? = nil,
      heading_level : Int32? = nil,
      non_breakable : Bool? = nil,
      quote_level : Int32? = nil,
      horizontal_rule : Bool? = nil,
      checked : Bool? = nil,
      task : Bool? = nil,
      list_format : TextListFormat? = nil,
      table_format : TextTableFormat? = nil,
      frame_formats : Array(TextFrameFormat)? = nil,
      @alert_kind : AlertKind? = nil,
      @code_language : String? = nil,
      @image : TextImageFormat? = nil,
    )
      @indent = indent
      @top_margin = top_margin
      @bottom_margin = bottom_margin
      @bg = Colors.to_native bg
      @heading_level = heading_level
      @non_breakable = non_breakable
      @quote_level = quote_level
      @horizontal_rule = horizontal_rule
      @checked = checked
      @task = task
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

    # Whether the block resists being broken across pages/frames.
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

    # Whether a task item is checked (Qt's `MarkerType::Checked`).
    def checked? : Bool
      @checked || false
    end

    # Whether this block is a list item with a task box: an item of a
    # `Checkbox`-style list unless `task: false` makes it a plain one, or an
    # item of any other list given `task: true`.
    def task? : Bool
      return false unless lf = @list_format
      task = @task
      task.nil? ? lf.style.checkbox? : task
    end

    # Whether this block is a line of a fenced code block (`#code_language`
    # set).
    def code_block? : Bool
      !@code_language.nil?
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
        task: patch.@task.nil? ? @task : patch.@task,
        list_format: patch.list_format || @list_format,
        table_format: patch.table_format || @table_format,
        code_language: patch.code_language || @code_language,
        frame_formats: patch.frame_formats || @frame_formats,
        alert_kind: patch.alert_kind || @alert_kind,
        image: patch.image || @image,
      )
    end

    # A full-field copy overriding exactly the given nil-able properties. Every
    # field is forwarded from the `@`-ivars, so adding a block property means
    # editing this once.
    private def copy_with(*, list_format = @list_format, checked = @checked, task = @task, table_format = @table_format, frame_formats = @frame_formats, top_margin = @top_margin, bottom_margin = @bottom_margin) : TextBlockFormat
      TextBlockFormat.new(
        alignment: @alignment, indent: @indent, top_margin: top_margin,
        bottom_margin: bottom_margin, bg: @bg, heading_level: @heading_level,
        non_breakable: @non_breakable, quote_level: @quote_level,
        horizontal_rule: @horizontal_rule, checked: checked, task: task, list_format: list_format,
        table_format: table_format, frame_formats: frame_formats, alert_kind: @alert_kind,
        code_language: @code_language, image: @image)
    end

    # A copy with the list reference replaced, or cleared with `nil` — which
    # `#merge` cannot express, since nil there means "unspecified".
    def with_list_format(lf : TextListFormat?) : TextBlockFormat
      copy_with(list_format: lf)
    end

    # A copy with the checkbox state replaced, or cleared with `nil`. `#merge`
    # cannot set `false` over a stored value, same as `#with_list_format`.
    def with_checked(checked : Bool?) : TextBlockFormat
      copy_with(checked: checked)
    end

    # A copy with the task-box override replaced, or cleared with `nil` (the
    # list decides again), same as `#with_checked`.
    def with_task(task : Bool?) : TextBlockFormat
      copy_with(task: task)
    end

    # A copy with the table reference replaced, or cleared with `nil`, same as
    # `#with_list_format`.
    def with_table_format(tf : TextTableFormat?) : TextBlockFormat
      copy_with(table_format: tf)
    end

    # A copy with the frame path replaced, or `nil` to move the block to the
    # root frame. `#merge` cannot express clearing, same as `#with_list_format`.
    def with_frame_formats(ff : Array(TextFrameFormat)?) : TextBlockFormat
      copy_with(frame_formats: ff)
    end

    # A copy with the top margin replaced, or cleared with `nil` — `#merge`
    # cannot clear a set value. Clear with `nil` (not `0`) so an otherwise-empty
    # result still equals `TextBlockFormat.default`.
    def with_top_margin(margin : Int32?) : TextBlockFormat
      copy_with(top_margin: margin)
    end

    # A copy with the bottom margin replaced, or cleared with `nil`, mirroring
    # `#with_top_margin`.
    def with_bottom_margin(margin : Int32?) : TextBlockFormat
      copy_with(bottom_margin: margin)
    end

    # Indent cells per list nesting level (`TextListFormat#indent - 1`
    # levels deep) — the terminal stand-in for Qt's per-level pixel indent.
    LIST_INDENT_CELLS = 2

    # Cells one side of the block's frame nesting takes: 2 per bordered
    # level (bar + gap) plus each level's margin. Frames are symmetric, so
    # this is both the left and the right inset.
    def frame_inset_cells : Int32
      path = @frame_formats || return 0
      w = 0
      path.each { |f| w += (f.border? ? 2 : 0) + f.margin }
      w
    end

    # Cells left of the block's text a view lays out before it — frame
    # insets, quote bars (2 per level), the list nesting indent and the
    # block indent — less any list marker or alert chip, whose width is the
    # view's (its glyphs). With `#frame_inset_cells` on the right, what the
    # block's text has of a text width (Qt's block indent and margins in
    # `QTextDocumentLayout`).
    def leading_inset_cells : Int32
      w = frame_inset_cells + quote_level * 2 + indent
      if lf = @list_format
        w += (lf.indent - 1) * LIST_INDENT_CELLS
      end
      w
    end

    # Whether every property but `quote_level` and `alert_kind` is unset.
    def quote_only? : Bool
      @alignment.nil? && @indent.nil? && @top_margin.nil? && @bottom_margin.nil? &&
        @bg.nil? && @heading_level.nil? && @non_breakable.nil? && @horizontal_rule.nil? &&
        @checked.nil? && @task.nil? && @list_format.nil? && @table_format.nil? &&
        @frame_formats.nil? && @code_language.nil? && @image.nil?
    end

    def_equals_and_hash @alignment, @indent, @top_margin, @bottom_margin, @bg, @heading_level, @non_breakable, @quote_level, @horizontal_rule, @checked, @task, @list_format, @table_format, @frame_formats, @alert_kind, @code_language, @image
  end

  # List format (Qt `QTextListFormat`): marker style, nesting depth, numbering
  # start and prefix/suffix. One *instance* is shared by all member blocks of a
  # list, and instance identity IS list identity — so treat instances as
  # one-per-list, not as interchangeable values.
  class TextListFormat < TextFormat
    enum Style
      Disc
      Circle
      Square
      # A GFM task-list marker (`[x]`/`[ ]`). The per-item checked state (and
      # a plain item's `task: false`) lives on the member block, since the
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

    # Clamps an imported ordered-list `start` into the sane range shared by
    # every importer: at least 1 (a `0.`/negative start renders as `1.`) and at
    # most 1_000_000, since larger values overflow the plain-Int32
    # marker/numbering arithmetic downstream. The single choke point all three
    # interchange importers (markdown, HTML, tags) route through.
    def self.sanitize_start(n : Int32) : Int32
      n.clamp(1, 1_000_000)
    end

    # The rendered marker of 0-based item *item* under this format, including
    # the separating trailing space: `"• "`, `"3. "`, `"c) "`, `"[x] "`…
    # A task item (`task`, `TextBlockFormat#task?`) shows its box in place
    # of the bullet or number, as Qt draws a block marker, `checked`
    # selecting the mark; a plain item of a `Checkbox` list shows a disc.
    def marker(item : Int32, tier : Glyphs::Tier = Glyphs::Tier::Unicode, checked : Bool = false, task : Bool = style.checkbox?) : String
      if task
        # `[x]`/`[ ]` in the ascii tier, `[✓]`/`[ ]` in unicode — all
        # single-width cells.
        mark = checked ? Glyphs[Glyphs::Role::CheckboxChecked, tier] : Glyphs[Glyphs::Role::CheckboxUnchecked, tier]
        return "#{Glyphs[Glyphs::Role::CheckboxOpen, tier]}#{mark}#{Glyphs[Glyphs::Role::CheckboxClose, tier]} "
      end
      case style
      when .disc?, .checkbox? then "#{Glyphs[Glyphs::Role::IconBullet, tier]} "
      when .circle?           then "#{Glyphs[Glyphs::Role::IconCircle, tier]} "
      when .square?           then "#{Glyphs[Glyphs::Role::IconSquareFilled, tier]} "
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

  # Frame format (Qt `QTextFrameFormat`). Margins and border in cells; the
  # border renders as box-drawing.
  class TextFrameFormat < TextFormat
    getter margin : Int32
    getter? border : Bool

    class_getter default : TextFrameFormat { new }

    def initialize(*, @margin : Int32 = 0, @border : Bool = false)
    end
  end

  # Table format (Qt `QTextTableFormat < QTextFrameFormat`). One *instance* per
  # table — instance identity is table identity, referenced from every member
  # block's `TextBlockFormat#table_format`, as with `TextListFormat`.
  class TextTableFormat < TextFrameFormat
    getter columns : Int32

    # Per-column horizontal alignment (GFM `:---:`); `nil`/missing = left.
    getter alignments : Array(Tput::AlignFlag)?

    def initialize(*, @columns : Int32 = 1, margin : Int32 = 0, border : Bool = true, @alignments : Array(Tput::AlignFlag)? = nil)
      super(margin: margin, border: border)
    end
  end

  # An image (Qt `QTextImageFormat < QTextCharFormat`). The Markdown
  # importer records one on the block a paragraph holding nothing but an
  # image becomes (`TextBlockFormat#image`), keeping the block's text as the
  # picture glyph and the alt text: a view that draws images
  # (`Widget::TextEdit#images_enabled?`) shows the picture above that row,
  # and anything that reads the text alone — the exporters, the clipboard,
  # the caret — still sees the alt text. `#name` is as written in the
  # source; a view resolves it against the document's `TextDocument#base_url`.
  class TextImageFormat < TextCharFormat
    # Image source (path or URL), as written.
    getter name : String

    # The alternative text (Markdown's `![alt]`, HTML's `alt=`): what stands
    # in for the picture where it cannot be drawn.
    getter alt : String

    # The title (`![alt](src "title")`), or `nil`.
    getter title : String?

    # Desired size in cells; `nil` = natural.
    getter width : Int32?
    getter height : Int32?

    def initialize(*, @name : String = "", @alt : String = "", @title : String? = nil, @width : Int32? = nil, @height : Int32? = nil)
      super()
    end

    # What stands in for a picture on the cell grid. The glyph comes from the
    # registry (so `Glyphs.set` retheming and ASCII-fied output apply) at the
    # `extended` tier — `🖼`, a text-presentation emoji of one column —
    # rather than the `unicode` tier rules and quote bars use: those must
    # stay box-drawing to join borders, while the placeholder is content,
    # drawn by the emoji-capable terminals this is read on. An importer has
    # no screen to ask for the effective tier.
    def self.placeholder : String
      Glyphs.str(Glyphs::Role::IconImage, Glyphs::Tier::Extended)
    end

    def_equals_and_hash @name, @alt, @title, @width, @height
  end

  # Table cell format (Qt `QTextTableCellFormat < QTextCharFormat`).
  class TextTableCellFormat < TextCharFormat
    getter row_span : Int32
    getter column_span : Int32

    def initialize(*, @row_span : Int32 = 1, @column_span : Int32 = 1)
      super()
    end
  end
end
