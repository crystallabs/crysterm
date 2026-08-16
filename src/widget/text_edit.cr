require "./abstract_scroll_area"
require "../mixin/interactive"
require "../mixin/text_editing"

module Crysterm
  class Widget
    # Rich text editor over a `TextDocument`, modeled after Qt's `QTextEdit`.
    #
    # Derives `AbstractScrollArea` (Qt: `QTextEdit < QAbstractScrollArea`) and
    # shares all navigation/selection/kill/mouse behavior with `LineEdit`/
    # `PlainTextEdit` through `Mixin::TextEditing`; the difference is the
    # buffer adapter — `Mixin::TextEditing::DocumentBuffer` maps the mixin's
    # flat positions onto the document and routes mutations through its
    # undoable editing API, so character formats survive edits and `C-z`/`M-z`
    # undo/redo work.
    #
    # Layout is a per-block wrap cache: each `TextBlock` wraps independently
    # into display rows (reusing `Widget#wrap_lines`), invalidated by the
    # document's `ContentsChanged` for only the touched blocks, so edits stay
    # O(block), not O(document). The assembled rows fill `@wrapped_lines` — the same
    # structure the shared caret/selection geometry already reads — while
    # `@printable_content` stays empty: the base `base_render` pass paints only background/
    # borders/scroll bars, and `#paint_document` then writes the fragments
    # directly into the cell buffer with packed attributes. No tag or SGR
    # string is ever generated.
    #
    # The document is settable and shareable between views (Qt semantics):
    # `TextEdit.new(document: doc)` or `edit.document = doc`.
    #
    # <!-- widget-examples:capture v1 -->
    # ![TextEdit screenshot](../../tests/widget/textedit/textedit.5s.apng)
    # <!-- /widget-examples:capture -->
    class TextEdit < AbstractScrollArea
      include Mixin::Interactive
      include Mixin::TextEditing
      include Mixin::TextEditing::DocumentBuffer

      # A render-time format overlay (Qt `QTextEdit::ExtraSelection`): the
      # cursor's selected range is painted with `format` merged over the text's
      # own formats. With no selection and `full_width` set, the whole display
      # row(s) holding the cursor position are painted — the idiom for a
      # current-line highlight.
      record ExtraSelection,
        cursor : TextCursor,
        format : TextCharFormat,
        full_width : Bool = false

      # Indent cells per list nesting level (`TextListFormat#indent - 1`
      # levels deep) — the terminal stand-in for Qt's per-level pixel indent.
      LIST_INDENT_CELLS = 2

      # Per-kind icon glyph for a GFM alert block's title chip (see
      # `#alert_chip`) — the "distinct per kind" look GitHub's alert
      # admonitions use, expressed through the existing `Glyphs::Role` icon
      # palette rather than new literal characters.
      ALERT_ICON_ROLES = {
        TextBlockFormat::AlertKind::Note      => Glyphs::Role::IconInfo,
        TextBlockFormat::AlertKind::Tip       => Glyphs::Role::IconLightning,
        TextBlockFormat::AlertKind::Important => Glyphs::Role::IconCritical,
        TextBlockFormat::AlertKind::Warning   => Glyphs::Role::IconWarning,
        TextBlockFormat::AlertKind::Caution   => Glyphs::Role::IconWarningSign,
      }

      # The title chip painted at a GFM alert block's text start on its first
      # row — `"ℹ NOTE "` and so on — using the exact same decoration-marker
      # mechanism (`RowMeta#marker` / `#block_deco_cells`) a list uses for its
      # bullet/number, so it's mutually exclusive with `list_format` (an alert
      # block is never also a list item) and needs no layout changes of its
      # own.
      private def alert_chip(kind : TextBlockFormat::AlertKind, tier : Glyphs::Tier) : String
        "#{Glyphs[ALERT_ICON_ROLES[kind], tier]} #{kind.to_s.upcase} "
      end

      # Which marker patterns typed at the start of a block auto-convert it
      # into a list item (see `#auto_formatting`). Qt's `AutoFormattingFlag`
      # has only `AutoBulletList`; `NumberedList` (`"1. "`, `"1) "`) is an
      # extension in the same spirit.
      @[Flags]
      enum AutoFormatting
        # `- `, `* ` or `+ ` at block start starts a disc list.
        BulletList
        # `N. ` or `N) ` at block start starts a decimal list at N.
        NumberedList
      end

      # Enables auto-formatting while typing (Qt `QTextEdit::autoFormatting`;
      # default `None`, as in Qt): typing a list marker followed by a space
      # at the start of a plain block converts the block into a fresh list
      # item — the marker text is removed and re-appears as the rendered
      # list decoration. One undo step reverts the conversion (restoring the
      # typed marker text), a second removes the marker keystrokes.
      property auto_formatting : AutoFormatting = AutoFormatting::None

      # Per-display-row decoration metadata, parallel to `@wrapped_lines`. `offset` is
      # the column where the row's text starts (frame insets + quote bars +
      # indents + list marker + alignment shift), read by the shared geometry
      # through `#row_text_x_offset`; `marker` is the list marker painted at the
      # text's left edge (first row of a list item only); a `margin` row is blank
      # and holds no buffer positions (block margins and frame border rows).
      # `fborder` marks a frame border row: `{path index of the frame, top?}` —
      # painted as the frame's horizontal border with corners, the enclosing
      # frames' side bars running through it.
      private record RowMeta,
        offset : Int32,
        marker : String? = nil,
        margin : Bool = false,
        fborder : Tuple(Int32, Bool)? = nil

      # One block's cached wrap plus the decoration widths it was wrapped
      # for — list renumbering can change a marker's width (`"9. "` →
      # `"10. "`) without touching the block, so a mismatch forces a re-wrap;
      # `rdeco` is the right-side inset (frame borders/margins), which
      # shrinks the wrap width the same way.
      private record BlockLayout,
        deco : Int32,
        rdeco : Int32,
        lines : CLines

      # Colors for the structural decorations this widget paints itself
      # (list markers, quote bars, horizontal rules) — the same palette the
      # interchange importers use for text-level coloring, so a structurally
      # built document looks like an imported one. Stamped onto the document
      # (`TextDocument#theme`) on assignment and adoption, so
      # `doc.markdown = x` colors the same as this widget's `markdown=`.
      getter theme : TextTheme = TextTheme.default

      def theme=(value : TextTheme) : TextTheme
        @theme = value
        document.theme = value
        value
      end

      getter extra_selections = [] of ExtraSelection

      def extra_selections=(list : Array(ExtraSelection))
        @extra_selections = list
        update
        update! if window?
        list
      end

      @scrollable = true
      # Same scroll model as `PlainTextEdit`: `@child_base` is the top visible
      # wrapped row, `@child_offset` stays 0, the `ScrollBar` drives the
      # viewport top and the caret (`@cursor_pos`) is tracked separately.
      @scrollbar_policy = ScrollBarPolicy::AsNeeded
      # Engages with `wrap_content: false` (long lines overflow to the right).
      @horizontal_scrollbar_policy = ScrollBarPolicy::AsNeeded

      # Per-block wrap cache, keyed by `TextBlock` identity: each entry is the
      # standalone `CLines` `#wrap_block` produced for that block under the
      # current `@layout_key`, wrapped at `colwidth - deco`. `ContentsChanged`
      # deletes the touched blocks' entries; `#rebuild_layout` rebuilds misses
      # (and deco-width mismatches) and sweeps entries whose blocks left the
      # document.
      @block_layouts = {} of UInt64 => BlockLayout
      @block_layouts_swap = {} of UInt64 => BlockLayout

      # Decoration metadata per assembled display row (see `RowMeta`),
      # rebuilt alongside `@wrapped_lines` by `#rebuild_layout`.
      @row_meta = [] of RowMeta

      # The layout inputs `@block_layouts` entries are valid for:
      # {colwidth, child_base_x, wrap_content?, content_margin_x}. Any change
      # invalidates every block (a width change re-wraps everything).
      @layout_key : Tuple(Int32, Int32, Bool, Int32)? = nil

      # Bumped on every document `ContentsChanged`; `@layout_revision` is the
      # revision `@wrapped_lines` was assembled at, `@rendered_revision` the one the
      # caret-following scroll last ran for.
      @doc_revision = 0
      @layout_revision = -1

      # `style_to_attr` memo for the steady-frame path of `process_content`:
      # every frame with an unchanged layout still refreshes the base attr, so
      # the derivation is skipped until a style setter (or cascade swap)
      # invalidates it.
      @attr_memo = Style::AttrMemo.new
      @rendered_revision = -1

      def initialize(
        input_on_focus = false,
        max_length = nil,
        read_only = false,
        placeholder_text = nil,
        document : TextDocument? = nil,
        **input,
      )
        adopt_document document, input["content"]? || "", max_length, read_only

        super **(input.merge({keys: true}))

        placeholder_text.try { |v| @placeholder_text = v }

        finish_document_setup input_on_focus: input_on_focus, install_enter: !!input["keys"]?
      end

      # The inherited widget-content accessors historically went nowhere on
      # `TextEdit`: its paint path assembles from the document's block
      # layouts and never reads `@content`, so `content =` was a silent no-op
      # and `content` returned the constructor-time seed forever. Re-pointed
      # at the document in the widget's content language — the tag markup
      # (the same `{bold}…{/bold}` vocabulary plain widgets parse) — so all
      # of the widget's "set the text" entry points agree: `content=`/
      # `set_content`/`set_text` replace the document wholesale
      # (`TextDocument#set_tags` reset semantics; `no_tags` is
      # ignored) and `content` reads it back as tags. For an undoable partial
      # edit use the cursor API; for plain text use `value=`.
      def set_content(content = "", *, no_tags = false)
        return super unless @buf_content_delegated
        document.set_tags content.to_s
      end

      # :ditto:
      def set_text(content = "")
        set_content content
      end

      # :ditto:
      def content : String
        return super unless @buf_content_delegated
        document.tags
      end

      # Replaces the document's whole content from Markdown (Qt
      # `QTextEdit#setMarkdown`), colored by *theme* (this widget's `#theme`
      # by default). Same reset semantics as `TextDocument#set_markdown`:
      # not undoable, cursors rewind. Views sharing the document all update.
      def set_markdown(text : String, theme : TextTheme = @theme) : Nil
        document.set_markdown text, theme
        interchange_reset_caret
      end

      # `=`-setter spelling of `#set_markdown` (widget theme; use
      # `#set_markdown` for an explicit one).
      def markdown=(text : String) : String
        set_markdown text
        text
      end

      # Streams markdown into the document's end (see
      # `TextDocument#append_markdown`) — the incremental path a chat-style
      # producer feeds chunk by chunk. Complete constructs are parsed and
      # appended as their terminating blank line arrives; a trailing
      # incomplete one (an open code fence, a table mid-row, the last
      # paragraph) stays buffered until a later chunk completes it or
      # `#flush_markdown` forces it, so any chunking renders exactly like
      # `#set_markdown` of the whole text. The caret and scroll stay put, and
      # — unlike `#set_markdown` — inline TOCs are NOT refreshed (an append
      # is exactly the mid-stream shift `#refresh_tocs`'s manual policy
      # avoids); call `#refresh_tocs` when the stream ends. A `TocView`
      # sidebar tracks the document on its own either way.
      def append_markdown(chunk : String, theme : TextTheme = @theme) : Nil
        document.append_markdown chunk, theme
      end

      # Parses and appends whatever `#append_markdown` still holds buffered —
      # the end-of-stream signal.
      def flush_markdown(theme : TextTheme = @theme) : Nil
        document.flush_markdown theme
      end

      # Regenerates every inline table of contents from the current headings,
      # in this widget's `#theme`, returning whether any changed.
      #
      # Deliberately manual: a TOC that grew while the reader was below it would
      # shift every row under them mid-read, so this is what an application
      # binds to a re-render action or a key. `#set_markdown` already runs it —
      # a load is the one moment with no reading position to disturb. The
      # `TocView` sidebar needs none of this and tracks the document on its own.
      def refresh_tocs : Bool
        document.refresh_tocs @theme
      end

      # Replaces the document's whole content from HTML (Qt
      # `QTextEdit#setHtml`); otherwise like `#set_markdown`.
      def set_html(html : String, theme : TextTheme = @theme) : Nil
        document.set_html html, theme
        interchange_reset_caret
      end

      # `=`-setter spelling of `#set_html` (widget theme; use `#set_html` for
      # an explicit one).
      def html=(html : String) : String
        set_html html
        html
      end

      protected def reset_document_caches : Nil
        @block_layouts.clear
        @layout_key = nil
        @doc_revision += 1
        # An adopted document inherits this widget's palette (see `#theme`).
        document.theme = @theme
      end

      private def wire_document : Nil
        @ev_contents_change = document.on(Crysterm::Event::ContentsChanged) do |e|
          on_contents_change(e.position, e.chars_removed, e.chars_added, e.kind)
        end
      end

      # Document edit hook: drop the layout cache entries of the blocks now
      # overlapping the changed range (their wrapped rows are stale) and request
      # a repaint. Untouched blocks keep their rows — that's what makes an edit
      # O(block). Format-only changes (including block-format changes at a caret,
      # which report `removed == added == 0`) land in the same path: block format
      # drives the decoration width and thus the wrap. Decoration-width fallout on
      # *other* blocks (list renumbering) is caught by `BlockLayout#deco`
      # comparison in `#rebuild_layout` instead.
      #
      # The caret also follows here: an edit made by another actor on a shared
      # document shifts this view's caret/selection like a registered cursor. The
      # widget's own edits are skipped — the mixin moves the caret itself.
      private def on_contents_change(pos : Int32, removed : Int32, added : Int32, kind : TextDocument::ChangeKind) : Nil
        follow_document_change(kind, pos, removed, added)
        @doc_revision += 1
        blocks = document.blocks
        b1 = document.block_at(pos).index
        b2 = document.block_at(pos + added).index
        (b1..b2).each do |i|
          blocks[i]?.try { |b| @block_layouts.delete(b.object_id) }
        end
        update
        update! if window?
      end

      # === Layout ===

      # Replaces the base content pipeline: instead of parsing `@content`,
      # assemble `@wrapped_lines` from the per-block wrap cache. Returns whether a
      # relayout happened (base contract).
      def process_content(no_tags = false, awidth_hint : Int32? = nil)
        return false unless window?
        colwidth = (awidth_hint || awidth) - ihorizontal
        key = layout_cache_key(colwidth)
        if key == @layout_key && @layout_revision == @doc_revision && !@wrapped_lines.empty?
          # Steady frame. Keep the cached base attr fresh (a style change
          # recolors the background) — mirrors the base `process_content`. The
          # derivation is memoized on {identity, attr_revision}; no stamped-
          # default third gate is needed (unlike the base memo) because the
          # cached value is still compared against `@_parse_attr_default`, so
          # a `rebuild_layout` under a substituted style followed by a swap
          # back lands in the refresh below.
          da = @attr_memo.fetch(style)
          @_parse_attr_default = da if da != @_parse_attr_default
          return false
        end
        rebuild_layout(colwidth, key)
        # AsNeeded-bar convergence (see base `process_content`): the margin
        # the wrap consumed depends on the row count it produced. If the
        # produced rows flipped the bar's presence, re-wrap once — monotonic,
        # so two passes always suffice.
        key2 = layout_cache_key(colwidth)
        rebuild_layout(colwidth, key2) if key2 != key
        true
      end

      private def layout_cache_key(colwidth : Int32) : Tuple(Int32, Int32, Bool, Int32)
        {colwidth, @child_base_x, wrap_content?, content_margin_x}
      end

      # Assembles `@wrapped_lines` (rows + fake/real maps) and `@row_meta` from
      # per-block layouts, wrapping only blocks without a cache entry (or whose
      # decoration width changed). The swap hash keeps only blocks still in the
      # document, sweeping removed blocks' entries. Decorated blocks wrap at
      # `colwidth - deco`; block margins interleave blank rows that belong to the
      # block (`rtof`) but carry no buffer positions (absent from `ftor`,
      # `RowMeta#margin` set), which the shared geometry steps over.
      private def rebuild_layout(colwidth : Int32, key : Tuple(Int32, Int32, Bool, Int32)) : Nil
        @block_layouts.clear if key != @layout_key
        @layout_key = key
        @layout_revision = @doc_revision

        cl = @wrapped_lines
        cl.reset
        fake = cl.fake
        fake.clear
        meta = @row_meta
        meta.clear
        full_width = 0
        max_width = 0
        tier = glyph_tier
        # 0-based item counter per list instance (identity-keyed), advanced
        # in document order — the marker numbering source.
        list_items = {} of UInt64 => Int32

        fresh = @block_layouts_swap
        fresh.clear
        # Frame path of the previous block — boundary rows (frame borders)
        # are emitted where consecutive blocks' paths diverge.
        empty_path = [] of TextFrameFormat
        prev_path = empty_path
        document.blocks.each_with_index do |blk, bi|
          bf = blk.block_format
          marker = nil
          if lf = bf.list_format
            n = list_items[lf.object_id]? || 0
            list_items[lf.object_id] = n + 1
            marker = lf.marker(n, tier, bf.checked?)
          elsif kind = bf.alert_kind
            marker = alert_chip(kind, tier)
          end
          deco = block_deco_cells(bf, marker)
          rdeco = frame_inset(bf)
          entry = @block_layouts[blk.object_id]?
          bl = entry && entry.deco == deco && entry.rdeco == rdeco ? entry.lines : wrap_block(blk, Math.max(colwidth - deco - rdeco, 2))
          fresh[blk.object_id] = BlockLayout.new(deco, rdeco, bl)

          # Frame boundary rows: close the frames the previous block was in
          # and this one isn't (bottom borders, innermost first, attached to
          # the previous block), then open this block's new frames (top
          # borders, outermost first). Borderless frames add no row.
          path = bf.frame_formats || empty_path
          unless path.same?(prev_path) || (path.empty? && prev_path.empty?)
            common = 0
            while common < prev_path.size && common < path.size && prev_path[common].same?(path[common])
              common += 1
            end
            (prev_path.size - 1).downto(common) do |i|
              next unless prev_path[i].border?
              cl.rtof << bi - 1
              meta << RowMeta.new(0, margin: true, fborder: {i, false})
              cl.push ""
            end
            (common...path.size).each do |i|
              next unless path[i].border?
              cl.rtof << bi
              meta << RowMeta.new(0, margin: true, fborder: {i, true})
              cl.push ""
            end
          end
          prev_path = path

          bf.top_margin.times do
            cl.rtof << bi
            meta << RowMeta.new(0, margin: true)
            cl.push ""
          end

          # Center/right alignment is a per-wrapped-row extra shift within
          # the space the decorations leave. Wrap mode only: non-wrap rows
          # are viewport slices of arbitrarily long lines, where alignment
          # has no stable meaning.
          align = bf.alignment
          align = nil unless wrap_content? && align && (align.h_center? || align.right?)
          avail = Math.max(colwidth - deco - rdeco, 0)

          row_ids = cl.take_ftor_row
          first = true
          bl.lines.each do |row|
            shift = 0
            if align
              slack = avail - str_width(row)
              shift = Math.max(align.h_center? ? slack // 2 : slack, 0)
            end
            row_ids << cl.size
            cl.rtof << bi
            meta << RowMeta.new(deco + shift, first ? marker : nil)
            cl.push row
            first = false
          end
          cl.ftor << row_ids
          fake << blk.text

          bf.bottom_margin.times do
            cl.rtof << bi
            meta << RowMeta.new(0, margin: true)
            cl.push ""
          end

          full_width = Math.max(full_width, bl.full_width + deco + rdeco)
          max_width = Math.max(max_width, bl.max_width + deco + rdeco)
        end
        # Close the frames still open past the last block (bottom borders,
        # innermost first).
        unless prev_path.empty?
          last_bi = document.block_count - 1
          (prev_path.size - 1).downto(0) do |i|
            next unless prev_path[i].border?
            cl.rtof << last_bi
            meta << RowMeta.new(0, margin: true, fborder: {i, false})
            cl.push ""
          end
        end
        @block_layouts, @block_layouts_swap = fresh, @block_layouts

        cl.fake = fake
        cl.width = colwidth
        cl.base_x = @child_base_x
        cl.margin = key[3]
        cl.full_width = full_width
        cl.max_width = max_width
        cl.real = cl
        cl.attr = nil
        # Keep the printable content empty: the base `base_render` pass then paints
        # only the background fill (plus borders/bars/selection-on-fill), and
        # `#paint_document` draws the actual text over it.
        @printable_content = ""
        # The base attr cache normally refreshes in base `process_content`.
        # Routed through the memo so the first steady frame after a rebuild
        # hits instead of recomputing once more.
        @_parse_attr_default = @attr_memo.fetch(style)
      end

      # One block's display rows under the current layout inputs, via the same
      # wrap engine (`wrap_lines`) the base pipeline uses — identical cut
      # points, wide-char handling and `content_margin_x` reservation, and the
      # non-wrap `_hslice` viewport window. `wrap_width` is the column width left
      # after the block's decorations. TABs must be pre-expanded to match the
      # tab-expanded column units all the shared caret math runs in.
      private def wrap_block(blk : TextBlock, wrap_width : Int32) : CLines
        text = blk.text
        text = text.gsub('\t', style.tab_char * style.tab_size) if text.includes?('\t')
        wrap_lines(text, wrap_width)
      end

      # Decoration cells left of a block's text: frame insets (borders +
      # margins, outermost first), quote bars (2 per level), list nesting
      # indent, plain block indent, and the list marker.
      private def block_deco_cells(bf : TextBlockFormat, marker : String?) : Int32
        deco = frame_inset(bf) + bf.quote_level * 2 + bf.indent
        if lf = bf.list_format
          deco += (lf.indent - 1) * LIST_INDENT_CELLS
        end
        deco += str_width(marker) if marker
        deco
      end

      # Horizontal inset one side of a block's frame nesting consumes: 2
      # cells per bordered level (bar + gap) plus each level's margin. Frames
      # are symmetric, so this is both the left and the right inset.
      private def frame_inset(bf : TextBlockFormat) : Int32
        path = bf.frame_formats || return 0
        w = 0
        path.each { |f| w += (f.border? ? 2 : 0) + f.margin }
        w
      end

      # === Geometry hooks (see `Mixin::TextEditing`) ===

      # Where this row's text starts: the shared caret/mouse/selection math
      # adds it, `#paint_document` paints from it.
      private def row_text_x_offset(rl : Int32) : Int32
        @row_meta[rl]?.try(&.offset) || 0
      end

      # Steps over block-margin rows (no buffer positions) in the direction
      # of travel; when that runs off the edge, back the other way.
      private def nearest_text_row(rl : Int32, dir : Int32) : Int32
        r = rl
        while (m = @row_meta[r]?) && m.margin
          r += dir
        end
        if r < 0 || r >= @wrapped_lines.size
          r = rl
          while (m = @row_meta[r]?) && m.margin
            r -= dir
          end
        end
        r.clamp(0, Math.max(0, @wrapped_lines.size - 1))
      end

      # === Cursor / format API (Qt counterparts) ===

      # A `TextCursor` materializing this view's caret and selection (Qt
      # `textCursor`). A *snapshot*: mutating it edits the document but does
      # not move the widget's caret — assign it back via `#text_cursor=`.
      def text_cursor : TextCursor
        c = TextCursor.new(document, @selection_anchor || @cursor_pos)
        c.set_position(@cursor_pos, :keep_anchor)
        c
      end

      # Adopts *c*'s position/anchor as the widget caret/selection (Qt
      # `setTextCursor`).
      def text_cursor=(c : TextCursor)
        @cursor_pos = c.position.clamp(0, buf_size)
        @selection_anchor = c.selection? ? c.anchor.clamp(0, buf_size) : nil
        @goal_col = nil
        update
        update! if window?
      end

      # Format typing at the caret would get: the pending typing format, else
      # the preceding character's (Qt `currentCharFormat`).
      def current_char_format : TextCharFormat
        typing_format || document.typing_format_at(@cursor_pos)
      end

      # Merges *fmt* into the selection's char formats (undoable), or into
      # the typing format when nothing is selected (Qt `mergeCurrentCharFormat`).
      def merge_current_char_format(fmt : TextCharFormat) : Nil
        if r = selection_range
          document.apply_char_format(r.begin, r.end, fmt, merge: true)
          edit_cursor.set_position(r.end)
        else
          self.typing_format = current_char_format.merge(fmt)
        end
      end

      # Replaces the selection's char format (undoable), or the typing format
      # when nothing is selected (Qt `setCurrentCharFormat`).
      def current_char_format=(fmt : TextCharFormat) : Nil
        if r = selection_range
          document.apply_char_format(r.begin, r.end, fmt)
          edit_cursor.set_position(r.end)
        else
          self.typing_format = fmt
        end
      end

      # === Interchange (Qt setMarkdown/setHtml counterparts). Each set replaces
      # the document content wholesale — not undoable, caret to the start (Qt
      # behavior; contrast `#value=`, whose plain-text convention parks the caret
      # at the end). The document's `ContentsChanged` drives relayout, so no
      # display work happens here. ===

      {% for f in %w[tags markdown html] %}
        {% if f == "tags" %}
          # Replaces the content from {{ f.id }} markup.
          #
          # markdown/html deliberately have NO setters here: their themed
          # overloads (`#set_markdown`/`#set_html` near the top of the class,
          # defaulting to this widget's `#theme`) are the single definitions —
          # a 1-arg def generated here would REPLACE the defaulted-arg def
          # entirely (not overload it), dropping both the 2-arg themed call
          # and the widget-theme default.
          def set_{{ f.id }}(str : String) : Nil
            document.set_{{ f.id }}(str)
            interchange_reset_caret
          end

          # :ditto:
          def {{ f.id }}=(str : String) : String
            set_{{ f.id }}(str)
            str
          end
        {% end %}

        # The content as {{ f.id }} markup.
        def to_{{ f.id }} : String
          document.to_{{ f.id }}
        end
      {% end %}

      private def interchange_reset_caret : Nil
        @cursor_pos = 0
        clear_selection
        @goal_col = nil
        @typing_format = nil
      end
    end
  end
end
