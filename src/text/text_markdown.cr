require "markd"

module Crysterm
  # Markdown import/export for `TextDocument` — the
  # `QTextDocument::setMarkdown`/`toMarkdown` counterpart. Import walks the
  # `markd` CommonMark AST straight into blocks/fragments (no tag-string
  # intermediate); export walks blocks back to markdown, keying on *semantic*
  # properties (`heading_level`, `TextCharFormat#code?`, `anchor_href`), so
  # the `TextTheme` colors the importer applies never affect round-trips.
  #
  # Mapping:
  #
  # - Headings → `TextBlockFormat#heading_level` + theme heading color.
  # - `**`/`*`/`~~`/backticks/links → char formats (`code` spans also get the
  #   theme code colors); images degrade to their alt text.
  # - Paragraph spacing → `TextBlockFormat#top_margin` on the block that
  #   follows (the margins re-base; exporters read the margins back as blank
  #   lines, and HTML carries them as `margin-*` styles, so the formats stay
  #   cross-convertible). Spacing *interior* to a quote (a heading or code
  #   fence inside a blockquote) stays a literal quote-level separator block —
  #   it is quoted content and renders the quote bar. A hard line break
  #   starts a new block with neither.
  # - Lists → one `TextList` per markdown list (disc/decimal style, nesting
  #   via `TextListFormat#indent`); the widget renders markers/indent as
  #   decorations. An item's continuation blocks get a plain block indent
  #   approximation. A GFM task list (any item with `[x]`/`[ ]`) becomes a
  #   `Checkbox`-style list; each item's checked state rides on its block
  #   (`TextBlockFormat#checked?`), and the marker renders as `[x]`/`[ ]`.
  # - Blockquotes → `TextBlockFormat#quote_level`; thematic breaks → an
  #   empty `horizontal_rule` block.
  # - Fenced code → one block per line, `code`-flagged fragments over a
  #   theme-code-bg block (the exporter's fence detector); the fence info
  #   string is not kept.
  module TextMarkdown
    # Thematic-break rule the importer emits (and the exporter detects, along
    # with plain `-` runs).
    def self.rule_text : String
      Glyphs[Glyphs::Role::LineHorizontal, Glyphs::Tier::Unicode].to_s * 24
    end

    # One blockquote-level prefix (`│ `).
    def self.quote_prefix : String
      "#{Glyphs[Glyphs::Role::LineVertical, Glyphs::Tier::Unicode]} "
    end

    # The literal marker text a GFM alert's title line renders as/reads back
    # from — `"[!NOTE]"`, `"[!TIP]"`, … (the github.com blockquote extension:
    # https://github.github.com/gfm/, as used on github.com). The single
    # source both the importer (matching) and exporter (emitting) key off, so
    # the two stay in lockstep.
    def self.alert_marker(kind : TextBlockFormat::AlertKind) : String
      "[!#{kind.to_s.upcase}]"
    end

    # The comment fence a `TextToc` exports as. GFM has no table-of-contents
    # marker at all — github.com renders `[TOC]` as literal text — so the
    # tooling around it settled on HTML comments, which are a valid CommonMark
    # HTML block (type 2) and render as *nothing*. Because the pair brackets a
    # region, the generated entries can live inside it: the saved file shows a
    # real, working contents list in any CommonMark renderer, while re-import
    # still recognizes the region. A bare marker would force a choice between
    # the two.
    FENCE_OPEN  = "<!-- toc -->"
    FENCE_CLOSE = "<!-- tocstop -->"

    # Bare markers accepted on *import* only. `[TOC]` is Python-Markdown's (and
    # so PHP Markdown Extra's, Typora's, Doxygen's); `[[_TOC_]]` is GitLab's.
    # Being liberal here costs nothing and is what a document written elsewhere
    # will contain; export always normalizes to the fence.
    BARE_MARKERS = {"[toc]", "[[toc]]", "[[_toc_]]"}

    # Whether *text* is a bare TOC marker in any accepted spelling.
    #
    # Spelled to run per block per parse (`.fold_tocs`' guard) without the
    # `strip.downcase` copies the obvious form makes: `String#strip` returns
    # `self` when there is nothing to strip, and each candidate is compared
    # case-insensitively in place.
    def self.toc_marker?(text : String) : Bool
      s = text.strip
      BARE_MARKERS.any? { |m| s.size == m.size && s.compare(m, case_insensitive: true).zero? }
    end

    # Parses markdown into detached blocks.
    def self.parse(text : String, theme : TextTheme = TextTheme.default) : Array(TextBlock)
      # `source_pos` records each block's source line/column so the importer
      # can tell a real `[x]` task marker from an escaped `\[x\]` one — markd
      # resolves the escape before the AST, so the text nodes are identical.
      doc = Markd::Parser.parse(text, Markd::Options.new(source_pos: true))
      fold_tocs(Importer.new(theme, text).import(doc))
    end

    # Serializes *blocks* to markdown.
    def self.generate(blocks : Array(TextBlock)) : String
      Exporter.new.export(unfold_tocs(blocks))
    end

    # This block's TOC frame format, or nil — the innermost one, so a TOC
    # nested inside another frame still resolves.
    protected def self.toc_format_of(block : TextBlock) : TextTocFormat?
      f = block.block_format.frame_formats.try(&.reverse_each.find(&.is_a?(TextTocFormat)))
      f.as(TextTocFormat?)
    end

    # Import pass: turns a `<!-- toc -->` … `<!-- tocstop -->` pair — or a bare
    # marker — into a `TextToc` frame, dropping the fence blocks themselves.
    #
    # The enclosed blocks are *kept*, not discarded: they are already valid
    # entries, so a fragment paste and a document that is never refreshed both
    # still show a contents list. They are derived data all the same, and the
    # first `TextDocument#refresh_tocs` replaces them — which
    # `TextDocument#set_markdown` runs, so a loaded document is always current.
    #
    # An unterminated open fence is left alone and exports as the literal HTML
    # comment it is.
    protected def self.fold_tocs(blocks : Array(TextBlock)) : Array(TextBlock)
      return blocks unless blocks.any? { |b| fence_open?(b) || bare_marker?(b) }
      res = [] of TextBlock
      i = 0
      while i < blocks.size
        b = blocks[i]
        if fence_open?(b)
          close = (i + 1...blocks.size).find { |j| fence_close?(blocks[j]) }
          unless close
            res << b
            i += 1
            next
          end
          body = blocks[(i + 1)...close]
          fmt = TextTocFormat.new(infer_options(body))
          # An empty fence still needs a block, or the frame has nowhere to live
          # and `TextToc#refresh` can never find it again.
          body = [TextBlock.new("", TextCharFormat.default, TextToc.context_format(b.block_format))] if body.empty?
          body.each { |x| x.block_format = stamp_toc(x.block_format, fmt) }
          res.concat body
          i = close + 1
        elsif bare_marker?(b)
          res << TextBlock.new("", TextCharFormat.default,
            stamp_toc(TextToc.context_format(b.block_format), TextTocFormat.new))
          i += 1
        else
          res << b
          i += 1
        end
      end
      res
    end

    # What can be read back out of a fenced region, which carries the entries
    # but not the `TocOptions` that produced them.
    #
    # A leading heading is a `TocOptions#title` — that is the only thing that
    # generates one — and it renders at `min_level` by construction, so the two
    # recover together and a titled TOC round-trips exactly. Everything else
    # (`numbering`, `links`, and `min_level` when there is no title) reverts to
    # the defaults: the ecosystem's fence has nowhere to put configuration, and
    # inventing an attribute syntax would forfeit the portability that made the
    # fence the right export in the first place.
    private def self.infer_options(body : Array(TextBlock)) : TocOptions
      first = body.first?
      return TocOptions.new unless first && first.block_format.heading?
      TocOptions.new(title: first.text, min_level: first.block_format.heading_level)
    end

    # A bare marker only counts as one where a TOC could actually go: not
    # inside a code block, where `[TOC]` is sample text rather than a
    # directive, and not as a list item.
    #
    # The length gate and first-char probe reject almost every block before
    # `toc_marker?` even strips: no accepted spelling is shorter than `[toc]`,
    # and all of them open with `[`.
    private def self.bare_marker?(block : TextBlock) : Bool
      text = block.text
      return false if text.size < 5 # "[toc]"
      opener = false
      text.each_char do |c|
        next if c.whitespace?
        opener = c == '['
        break
      end
      return false unless opener
      return false unless toc_marker?(text)
      return false if block.block_format.list_format
      !block.fragments.first?.try(&.format.code?)
    end

    # Export pass: brackets each TOC region with its fence blocks. The inverse
    # of `.fold_tocs`, and deliberately a plain list transform — the fences then
    # travel through the ordinary exporter as the HTML blocks they are, which is
    # what gets their blank-line separation right for free.
    #
    # The *blocks* array is not mutated: only the returned list is new, and the
    # fence blocks inherit the region's quote level so a quoted TOC keeps its
    # `>` prefix.
    protected def self.unfold_tocs(blocks : Array(TextBlock)) : Array(TextBlock)
      return blocks unless blocks.any? { |b| toc_format_of(b) }
      res = [] of TextBlock
      i = 0
      while i < blocks.size
        fmt = toc_format_of(blocks[i])
        unless fmt
          res << blocks[i]
          i += 1
          next
        end
        outer = TextToc.context_format(blocks[i].block_format).with_frame_formats(nil)
        res << TextBlock.new(FENCE_OPEN, TextCharFormat.default, outer)
        while i < blocks.size && toc_format_of(blocks[i]).try(&.same?(fmt))
          res << blocks[i]
          i += 1
        end
        res << TextBlock.new(FENCE_CLOSE, TextCharFormat.default, outer)
      end
      res
    end

    private def self.fence_open?(block : TextBlock) : Bool
      fence_eq?(block.text, FENCE_OPEN)
    end

    private def self.fence_close?(block : TextBlock) : Bool
      fence_eq?(block.text, FENCE_CLOSE)
    end

    # Whether *text* equals *fence* modulo surrounding whitespace and letter
    # case — `text.strip.downcase == fence` without its two copies, because
    # the fence guards run per block on every parse: the length gate rejects
    # most blocks outright (stripping only removes, so a shorter text cannot
    # match), `String#strip` returns `self` when there is nothing to strip,
    # and the final comparison is case-insensitive in place.
    private def self.fence_eq?(text : String, fence : String) : Bool
      return false if text.size < fence.size
      s = text.strip
      s.size == fence.size && s.compare(fence, case_insensitive: true).zero?
    end

    private def self.stamp_toc(bf : TextBlockFormat, fmt : TextTocFormat) : TextBlockFormat
      bf.with_frame_formats((bf.frame_formats || [] of TextFrameFormat) + [fmt])
    end

    # Incremental import for a *streamed* markdown producer (the counterpart
    # of Textual's `Markdown.append`): a chunk buffer that releases
    # the largest prefix guaranteed to parse in isolation exactly as it would
    # inside the finished text, holding everything else pending. Markdown is
    # not chunk-decomposable — a chunk boundary can fall inside a code fence,
    # mid table row, or mid paragraph — so the only safe release points are
    # blank lines that no future chunk can reach back across.
    #
    # `#append` buffers a chunk and returns markdown ready to parse, or nil;
    # `#flush` returns whatever is still pending — the end-of-stream signal.
    # This class is pure text chunking: `TextDocument#append_markdown` owns one
    # per document and feeds the released pieces through `.parse`.
    #
    # A release point must satisfy, judged per complete line (a trailing line
    # still missing its `'\n'` is never released — it could yet grow):
    #
    # - It sits just past a blank line. Everything blank-terminated is closed
    #   for good — paragraphs (so a seam can never split what one-shot parsing
    #   would join: an unterminated paragraph, its soft/hard-break
    #   continuations and a pending setext underline all wait for their blank
    #   line), headings, GFM tables, HTML blocks of types 6/7.
    # - Not inside an open ```` ``` ````/`~~~` fence, where blank lines are
    #   content.
    # - Not inside an HTML block of types 1-5 (`<script|pre|style`, `<!--`,
    #   `<?`, `<!DECL`, `<![CDATA[`) — the kinds whose content runs across
    #   blank lines until a close condition (`HTML_OPEN_1_5`).
    # - Not between `FENCE_OPEN` and `FENCE_CLOSE`: the pair must reach
    #   `.fold_tocs` in one piece or the TOC frame never forms.
    # - Not while the scanned tail ends in a list, indented code, or a
    #   blockquote. A later indented line continues list and indented code
    #   across any number of blank lines (`"- a\n\n  b"` is one item); a
    #   blockquote *is* closed by its blank line, but the importer emits a
    #   quote-interior separator block between two abutting quote runs
    #   (`quote_break?` keys on the previous block's quote level), which
    #   reaches across a seam — so abutting quotes must parse in one piece.
    #   All three stay unsafe until a column-0 plain line proves the
    #   construct over. Conservative — a streamed list or quote run releases
    #   only once something follows it (or `#flush` forces it) — which
    #   trades latency, never correctness.
    #
    # Known limitation, shared with Textual's incremental path: a link
    # *reference definition* resolves only within one released piece.
    # Reference definitions are the one construct with document-wide scope, so
    # a definition and its use separated by a release stay literal text.
    class Stream
      # A list-item marker line at ≤3 indent — bullet or ordered, including a
      # bare `-` (an empty item). What makes the scanned tail continuable
      # across blank lines. `---` and `===` do not match (the char after the
      # marker must be space/tab/EOL), so thematic breaks and setext
      # underlines stay plain lines.
      ITEM_LINE = /\A {0,3}(?:[-+*]|\d{1,9}[.)])(?:[ \t]|\z)/
      # A blockquote marker line at ≤3 indent — the third continuable-tail
      # shape (see the class comment's last rule).
      QUOTE_LINE = /\A {0,3}>/
      # An opening code fence (CommonMark 4.5): a backtick fence's info string
      # may not contain a backtick; a tilde fence's may contain anything.
      BACKTICK_FENCE = /\A {0,3}(`{3,})[^`]*\z/
      TILDE_FENCE    = /\A {0,3}(~{3,})/
      # A closing fence candidate: nothing but a fence run and trailing
      # spaces. Valid only for the open fence's character at ≥ its length.
      CLOSING_FENCE = /\A {0,3}(`+|~+)[ \t]*\z/
      # CommonMark HTML blocks of types 1-5 are the only ones whose content
      # continues across blank lines (6/7 end at one); open/close line
      # conditions reused straight from markd so the two stay in lockstep
      # (`HTML_BLOCK_OPEN` also carries types 6-7 — sliced off; the close
      # list is types 1-5 already).
      HTML_OPEN_1_5  = Markd::Rule::HTML_BLOCK_OPEN[0, 5]
      HTML_CLOSE_1_5 = Markd::Rule::HTML_BLOCK_CLOSE

      # Everything appended and not yet released — the tail the next `#append`
      # continues scanning from.
      getter pending : String = ""

      # Byte offset into `@pending` of the first unscanned byte; only whole
      # `'\n'`-terminated lines are ever classified.
      @scan_pos = 0
      # Byte offset of the largest safe release point found so far (always
      # just past a blank line), or nil.
      @boundary : Int32?
      # Byte end of the last content line scanned; a boundary is only worth
      # releasing when content precedes it.
      @last_content_end = 0
      # Open fence state: the fence character and the minimum closing run.
      @fence_char : Char?
      @fence_len = 0
      # Close condition of an open HTML block of types 1-5, else nil.
      @html_close : Regex?
      # Between `FENCE_OPEN` and its `FENCE_CLOSE`.
      @toc_open = false
      # The scanned tail ends in a seam-crossing construct (list / indented
      # code / blockquote) — see the class comment's last rule.
      @unsafe_tail = false
      # The next content line opens a fresh region (start of input or right
      # after a blank line) — the one place `@unsafe_tail` can clear: a
      # column-0 non-item line there ends any open list or indented code
      # (and a fresh quote region re-flags itself right after).
      @at_region_start = true

      # Buffers *chunk* and returns the markdown now safe to parse in
      # isolation, or nil when everything (still) waits on future chunks.
      def append(chunk : String) : String?
        return if chunk.empty?
        @pending += chunk
        scan
        release
      end

      # Returns the pending tail — parse it as-is; whatever construct is open
      # simply ends, as it would at end of input — and resets the stream. Nil
      # when nothing but whitespace is pending (a pure-blank tail parses to
      # nothing).
      def flush : String?
        rest = @pending
        reset
        rest.each_char.any? { |c| !c.in?(' ', '\t', '\r', '\n') } ? rest : nil
      end

      private def reset : Nil
        @pending = ""
        @scan_pos = 0
        @boundary = nil
        @last_content_end = 0
        @fence_char = nil
        @fence_len = 0
        @html_close = nil
        @toc_open = false
        @unsafe_tail = false
        @at_region_start = true
      end

      # Classifies every newly complete line.
      private def scan : Nil
        while nl = @pending.byte_index('\n'.ord, @scan_pos)
          line = @pending.byte_slice(@scan_pos, nl - @scan_pos).chomp('\r')
          @scan_pos = nl + 1
          classify(line, @scan_pos)
        end
      end

      # Cuts the pending buffer at the recorded boundary, rebasing the scan
      # state (all offsets are byte-based; a boundary lies just past a `'\n'`,
      # so the cut is always on a character boundary).
      private def release : String?
        b = @boundary || return
        piece = @pending.byte_slice(0, b)
        @pending = @pending.byte_slice(b, @pending.bytesize - b)
        @scan_pos -= b
        @boundary = nil
        @last_content_end = Math.max(@last_content_end - b, 0)
        piece
      end

      # The line scanner: tracks open fence / HTML / TOC-fence regions, the
      # continuable-tail flag, and records a release boundary at every blank
      # line all the rules pass.
      private def classify(line : String, line_end : Int32) : Nil
        if fc = @fence_char
          if (m = CLOSING_FENCE.match(line)) && m[1][0] == fc && m[1].size >= @fence_len
            @fence_char = nil
          end
          @last_content_end = line_end # blank lines in a fence are content
          return
        end
        if re = @html_close
          @html_close = nil if line.matches?(re)
          @last_content_end = line_end
          return
        end
        if blank?(line)
          @at_region_start = true
          @boundary = line_end if @last_content_end > 0 && !@unsafe_tail && !@toc_open
          return
        end
        @last_content_end = line_end
        ind = indent_of(line)
        if @at_region_start
          @unsafe_tail = false if ind == 0 && !ITEM_LINE.matches?(line)
          @at_region_start = false
        end
        case line.strip.downcase
        when FENCE_OPEN
          @toc_open = true
          return
        when FENCE_CLOSE
          @toc_open = false
          return
        end
        if ind <= 3
          if m = BACKTICK_FENCE.match(line) || TILDE_FENCE.match(line)
            @fence_char = m[1][0]
            @fence_len = m[1].size
            return
          end
          core = line.lstrip
          if core.starts_with?('<') && (t = HTML_OPEN_1_5.index { |open| core.matches?(open) })
            # A close condition met on the opening line ends the block there
            # (`<!-- toc -->` itself is exactly that case).
            close = HTML_CLOSE_1_5[t]
            @html_close = close unless core.matches?(close)
            return
          end
        end
        @unsafe_tail = true if ind >= 4 || ITEM_LINE.matches?(line) || QUOTE_LINE.matches?(line)
      end

      # Only spaces/tabs (CommonMark's blank line; `'\r'` is chomped before).
      private def blank?(line : String) : Bool
        line.each_char.all? { |c| c == ' ' || c == '\t' }
      end

      # Leading indent in columns, tabs advancing to the next 4-stop.
      private def indent_of(line : String) : Int32
        ind = 0
        line.each_char do |c|
          case c
          when ' '  then ind += 1
          when '\t' then ind += 4 - (ind % 4)
          else           break
          end
        end
        ind
      end
    end

    # Markd AST → blocks. Inline formatting is a stack of `TextCharFormat`
    # patches (entering `Strong` pushes `bold: true`, …); the current format
    # is the fold of the stack over the default, so nesting works for free.
    private class Importer
      # The block-assembly / inline-patch core: `@blocks`/`@frags`/
      # `@block_format`, the patch stack (`@patches`/`@fmt`), `@quote_depth`,
      # `@list_stack`, `@pending_item`/`@pending_checked`, and the shared
      # `with_patch`/`current_format`/`start_block`/`commit_block`/
      # `adopt_table_blocks`/`finalize_blocks` methods. The markdown-specific
      # hooks (`format_extra_merge`, `take_margin`) are defined below; the
      # unshared `start_block` hooks fall back to the module's defaults.
      include TextImport::Builder

      # Chars of a task-list `[x] ` marker still to strip from upcoming text.
      @strip_task = 0
      # Chars of a GFM alert `[!NOTE] ` marker (plus the space its trailing
      # soft/hard break renders as) still to strip from upcoming text — same
      # idiom as `@strip_task`, set when a blockquote's first line is
      # recognized as an alert marker (`#detect_alert_kind`).
      @strip_alert = 0
      # One entry per currently-open blockquote (parallel to `@quote_depth`):
      # the alert kind that blockquote's own first line declared, or — for a
      # blockquote with no marker of its own — the enclosing alert's kind
      # inherited from the entry below it (nested content stays part of the
      # enclosing alert unless it opens its own). `nil` at every level means
      # "not inside an alert".
      @alert_stack = [] of TextBlockFormat::AlertKind?
      # Whether any block was emitted (suppresses spacing before the first).
      @emitted = false
      # Top-level spacing owed to the next emitted block (its `top_margin`).
      @pending_margin = false
      # Open `~~` strike toggle. markd leaves `~` literal, so `~~` is
      # detected in text nodes; the state persists across sibling inline
      # nodes (the exporter's own `~~**x**~~` puts the delimiters in text
      # nodes around the `Strong`) and clears at block end.
      @strike = false

      # Raw source lines, kept so `task_marker` can consult `source_pos` to
      # reject escaped `\[x\]` markers.
      @source : Array(String)

      def initialize(@theme : TextTheme, source : String = "")
        @source = source.split('\n')
      end

      def import(doc : Markd::Node) : Array(TextBlock)
        walk_children(doc)
        finalize_blocks
      end

      private def walk_children(node : Markd::Node) : Nil
        child = node.first_child?
        while child
          walk(child)
          child = child.next?
        end
      end

      private def walk(node : Markd::Node) : Nil
        case node.type
        when .paragraph?
          import_paragraph(node)
        when .heading?
          structure_separator
          start_block TextBlockFormat.new(heading_level: node.data["level"].as(Int32))
          with_patch(TextCharFormat.new(fg: @theme.heading_color)) { walk_children(node) }
          end_block
        when .block_quote?
          structure_separator
          @quote_depth += 1
          own_kind = detect_alert_kind(node)
          @alert_stack << (own_kind || @alert_stack.last?)
          @strip_alert = TextMarkdown.alert_marker(own_kind).size + 1 if own_kind
          walk_children(node)
          @alert_stack.pop
          @quote_depth -= 1
        when .list?
          import_list(node)
        when .item?
          set_item_marker(node)
          walk_children(node)
          # An empty item never opens a block; drop the pending marker so
          # it doesn't leak onto the next unrelated block.
          @pending_item = nil
          @pending_checked = false
          @strip_task = 0
        when .code_block?
          import_code_block(node)
        when .thematic_break?
          structure_separator
          start_block TextBlockFormat.new(horizontal_rule: true)
          end_block
        when .html_block?
          structure_separator
          node.text.chomp.split('\n').each do |line|
            start_block
            append_text line
            end_block
          end
        when .text?
          append_text node.text
        when .code?
          with_patch(TextCharFormat.new(code: true, fg: @theme.code_color, bg: @theme.code_bg)) do
            push_frag node.text
          end
        when .strong?
          with_patch(TextCharFormat.new(bold: true)) { walk_children(node) }
        when .emphasis?
          with_patch(TextCharFormat.new(italic: true)) { walk_children(node) }
        when .link?
          url = node.data["destination"]?.try(&.as(String))
          with_patch(TextCharFormat.new(fg: @theme.link_color, anchor_href: url)) { walk_children(node) }
        when .image?
          # No inline images on a cell grid: degrade to alt text.
          with_patch(TextCharFormat.new(fg: @theme.muted_color)) do
            push_frag "🖼 "
            walk_children(node)
          end
        when .soft_break?
          append_text " "
        when .line_break?
          # Hard break: new block in the same paragraph flow (no separator).
          end_block
          start_block
        when .html_inline?
          append_text node.text
        else
          walk_children(node)
        end
      end

      # A paragraph node — or a table, when its text has the GFM-table shape:
      # markd hands tables through as a plain paragraph of `|` rows.
      private def import_paragraph(node : Markd::Node) : Nil
        structure_separator
        # A table-shaped paragraph inside a list item stays ordinary item
        # content: import_table stamps no list membership, so taking the
        # table path there would detach it from the list and shift ordered
        # numbering (the exporter's lead escape keeps the `|` roundtrip
        # stable). Since the table path requires an empty list stack, check that
        # first and skip the full recursive `node_text` build entirely for the
        # (common) list-nested paragraph, which can never be a table.
        if @list_stack.empty? && (txt = node_text(node)) && TextTable.gfm_table?(txt)
          import_table(txt)
          return
        end
        start_block
        walk_children(node)
        end_block
      end

      # A list node: pushes its shared `TextListFormat` (instance identity =
      # list identity) for the item walks, then pops it.
      private def import_list(node : Markd::Node) : Nil
        # `top_level?`/`quote_break?` already both require an empty list
        # stack, so no explicit `@list_stack.empty?` guard is needed here.
        structure_separator
        ordered = node.data["type"]? != "bullet"
        # markd's `parse_list_marker` allows up to 9 numeral digits (start up to
        # ~999_999_999) and permits `start: 0` (`0. item`), so both the
        # overflow-adjacent range and the zero case are reachable — route
        # through the shared clamp like the HTML and tags importers.
        start = TextListFormat.sanitize_start((node.data["start"]?.try &.as(Int32)) || 1)
        style = if !ordered && task_list?(node)
                  TextListFormat::Style::Checkbox
                elsif ordered
                  TextListFormat::Style::Decimal
                else
                  TextListFormat::Style::Disc
                end
        @list_stack << TextListFormat.new(
          style: style,
          indent: @list_stack.size + 1,
          start: start)
        walk_children(node)
        @list_stack.pop?
      end

      # A fenced/indented code block: one code-bg block per line.
      private def import_code_block(node : Markd::Node) : Nil
        structure_separator
        fmt = TextCharFormat.new(code: true, fg: @theme.code_color)
        bf = TextBlockFormat.new(bg: @theme.code_bg)
        node.text.chomp.split('\n').each do |line|
          start_block bf
          @frags << TextFragment.new(line, fmt) unless line.empty?
          end_block
        end
      end

      # Emit a structural separator before the next block when one is owed:
      # between successive top-level structures, or between successive
      # structures at the current quote depth. Folds the `top_level? ||
      # quote_break?` gate that every structural walk site shares into one
      # place.
      private def structure_separator : Nil
        separator if top_level? || quote_break?
      end

      private def top_level? : Bool
        @list_stack.empty? && @quote_depth == 0
      end

      # Whether a quote-interior separator is owed before the next structure:
      # only *between* successive structures at the current quote depth — the
      # previously emitted block must itself sit at this depth or deeper.
      # Entering a quote owes nothing (the previous block is shallower), and
      # list machinery owns spacing inside items.
      private def quote_break? : Bool
        return false unless @quote_depth > 0 && @list_stack.empty?
        (@blocks.last?.try(&.block_format.quote_level) || 0) >= @quote_depth
      end

      # Paragraph spacing before the next structure: at top level a
      # `top_margin` on its first block (rendered as a blank row holding no
      # positions); inside a quote a literal quote-level separator block —
      # that blank line is quoted content and renders the quote bar (a
      # margin row would not). Suppressed before the very first structure.
      private def separator : Nil
        return unless @emitted
        if top_level?
          @pending_margin = true
        else
          bf = @quote_depth > 0 ? TextBlockFormat.new(quote_level: @quote_depth) : TextBlockFormat.default
          if @quote_depth > 0 && (kind = @alert_stack.last?)
            bf = bf.merge(TextBlockFormat.new(alert_kind: kind))
          end
          @blocks << TextBlock.new("", block_format: bf)
        end
      end

      # Hook (`TextImport::Builder#take_margin`): markdown's owed top-level
      # spacing is a flat `top_margin: 1`, gated by the `Bool` `@pending_margin`.
      private def take_margin(bf : TextBlockFormat) : TextBlockFormat
        return bf unless @pending_margin
        @pending_margin = false
        bf.merge(TextBlockFormat.new(top_margin: 1))
      end

      # The block-assembly `start_block`/`commit_block`/`adopt_table_blocks`
      # skeleton lives in `TextImport::Builder`; markdown needs no `start_block`
      # customization hooks (it has no per-item element styles, collapse mode,
      # or block-open bookkeeping), so it uses the module defaults.

      # Markdown's `end_block` wraps the shared `commit_block` with its own
      # strike reset (an unbalanced `~~` span ends with its block) and the
      # `@emitted` latch that suppresses spacing before the first block.
      private def end_block : Nil
        if kind = @alert_stack.last?
          @block_format = @block_format.merge(TextBlockFormat.new(alert_kind: kind))
        end
        # A marker consumed by this block (if any) never bleeds into the
        # next: a marker with no soft break after it (an alert whose first
        # line is a hard break, vanishingly rare) would otherwise leave a
        # stray count on `@strip_alert`.
        @strip_alert = 0
        commit_block
        if @strike # unbalanced `~~`: the strike span ends with its block
          @strike = false
          @fmt = nil
        end
        @emitted = true
      end

      # Appends a GFM table's pre-rendered blocks, carrying any enclosing quote
      # level. Cell inline markup degrades to its plain text (markd never parsed
      # it).
      private def import_table(txt : String) : Nil
        bs = TextTable.build_from_gfm(txt, @theme) || return
        adopt_table_blocks(bs)
        if kind = @alert_stack.last?
          q = TextBlockFormat.new(alert_kind: kind)
          bs.each { |b| b.block_format = b.block_format.merge(q) }
        end
        @emitted = true
      end

      # Marks the next block as this item's first block; a GFM task item
      # additionally becomes a `Checkbox`-list member (the enclosing list is
      # a checkbox list, per `task_list?`) with its checked state stashed for
      # `start_block`, and the literal `[x] ` prefix scheduled for stripping.
      private def set_item_marker(item : Markd::Node) : Nil
        lf = @list_stack.last?
        @pending_item = lf
        return unless lf && lf.style.checkbox?
        case task_marker(item)
        when :done then @pending_checked = true; @strip_task = 4
        when :todo then @pending_checked = false; @strip_task = 4
        else            @pending_checked = false # a plain item in a task list (rare)
        end
      end

      # Whether *list* is a GFM task list: any of its items begins with a
      # `[x]`/`[ ]` marker.
      private def task_list?(list : Markd::Node) : Bool
        child = list.first_child?
        while child
          return true if child.type.item? && task_marker(child)
          child = child.next?
        end
        false
      end

      # `:done` / `:todo` if *item* begins with a `[x]`/`[ ]` task marker, which
      # markd tokenizes as plain text.
      private def task_marker(item : Markd::Node) : Symbol?
        # Cheap source-position check first: it rejects `\[x\]` without touching
        # the item's content at all.
        return if md_escaped_marker?(item)
        # The regex only ever looks at the first four characters, so serialize
        # only those — `node_text` would build the item's *entire* subtree
        # (nested paragraphs, sublists and their items) into a String and throw
        # it away, once per item of every bullet list in the document.
        if md = leading_text(item, 4).match(/\A\[([ xX])\]\s/)
          md[1].downcase == "x" ? :done : :todo
        end
      end

      # Whether the item's leading `[` is backslash-escaped in the source.
      # markd resolves `\[` to a plain `[` text node, so the AST alone can't
      # distinguish `\[x\]` (a literal `[x]` in a plain bullet) from a real
      # `[x]` task marker; the item's first block starts at the `\` in the
      # escaped case and at the `[` in the real one.
      private def md_escaped_marker?(item : Markd::Node) : Bool
        para = item.first_child?
        return false unless para
        md_escaped_at?(para)
      end

      # Whether *node*'s leading character is backslash-escaped in the
      # source — the shared position check behind `#md_escaped_marker?`
      # (task-list `\[x\]`) and `#detect_alert_kind` (alert `\[!NOTE]`).
      private def md_escaped_at?(node : Markd::Node) : Bool
        line, col = node.source_pos[0]
        return false unless (l = @source[line - 1]?)
        l[col - 1]? == '\\'
      end

      # The GFM alert marker constants a blockquote's first line matches
      # exactly (github.com's blockquote extension) — case-sensitive, the
      # whole line, nothing else.
      ALERT_MARKER = /\A\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\z/

      # The alert kind *bq* (a `block_quote` node) opens, or `nil` if it's an
      # ordinary quote: its first child must be a paragraph whose first
      # inline node is plain text (not emphasis/code — GitHub's marker is
      # unformatted) and whose first *line* matches `ALERT_MARKER` exactly,
      # and not backslash-escaped (`\[!NOTE]` stays a plain quote, same
      # `md_escaped_marker?` idiom as task-list markers).
      private def detect_alert_kind(bq : Markd::Node) : TextBlockFormat::AlertKind?
        para = bq.first_child?
        return unless para && para.type.paragraph?
        first = para.first_child?
        return unless first && first.type.text?
        return if md_escaped_at?(para)
        first_line = node_text(para).split('\n', 2)[0]
        return unless md = first_line.match(ALERT_MARKER)
        TextBlockFormat::AlertKind.parse(md[1])
      end

      private def node_text(node : Markd::Node) : String
        String.build { |io| collect_text node, io }
      end

      # The first *limit* **codepoints** of what `#collect_text` would produce
      # for *node* — same traversal, same emission order, same `|` → `\|` remap
      # — stopping as soon as that many are accumulated. For a caller that only
      # inspects a fixed-length prefix this avoids serializing the whole
      # subtree. The result may be shorter than *limit* (short subtree), never
      # longer, and is always a prefix of `#node_text`'s output.
      private def leading_text(node : Markd::Node, limit : Int32) : String
        String.build { |io| collect_leading_text node, io, limit, 0 }
      end

      # `#collect_text`'s bounded twin. *n* is the number of codepoints written
      # so far; returns the updated count so sibling and parent loops can stop.
      private def collect_leading_text(node : Markd::Node, io : IO, limit : Int32, n : Int32) : Int32
        child = node.first_child?
        while child && n < limit
          case child.type
          when .text?
            t = child.text
            t = "\\|" if t == "|"
            n = append_bounded io, t, limit, n
          when .code?
            n = append_bounded io, child.text, limit, n
          when .soft_break?, .line_break?
            io << '\n'
            n += 1
          else
            n = collect_leading_text child, io, limit, n
          end
          child = child.next?
        end
        n
      end

      # Writes at most `limit - n` codepoints of *s* to *io*, returning the new
      # total.
      private def append_bounded(io : IO, s : String, limit : Int32, n : Int32) : Int32
        room = limit - n
        s = s[0, room] if s.size > room
        io << s
        n + s.size
      end

      private def collect_text(node : Markd::Node, io : IO) : Nil
        child = node.first_child?
        while child
          case child.type
          when .text?
            # A backslash-escaped `\|` surfaces as its own single-char text
            # node (markd already resolved the escape; an unescaped pipe
            # never splits off alone). Restore the backslash so the GFM
            # cell splitter doesn't read it as a cell boundary.
            t = child.text
            io << (t == "|" ? "\\|" : t)
          when .code?                     then io << child.text
          when .soft_break?, .line_break? then io << '\n'
          else                                 collect_text child, io
          end
          child = child.next?
        end
      end

      # Hook (`TextImport::Builder#format_extra_merge`): folds the open `~~`
      # strike toggle onto the patch-stack fold. `with_patch` and the rest of
      # `current_format` are shared.
      private def format_extra_merge(fmt : TextCharFormat) : TextCharFormat
        @strike ? fmt.merge(TextCharFormat.new(strike: true)) : fmt
      end

      private def push_frag(text : String) : Nil
        @frags << TextFragment.new(text, current_format) unless text.empty?
      end

      # Emits literal text: drops a pending task-marker prefix and treats
      # `~~` as a strike toggle (markd leaves `~` literal, and splits
      # backslash-escaped `\~` into single-char text nodes — those never
      # form a `~~` here, so escapes stay literal). GFM-ish flanking: an
      # opener can't precede whitespace, a closer can't follow it; a
      # delimiter at a node edge pairs across sibling inline nodes.
      private def append_text(str : String) : Nil
        if @strip_task > 0
          drop = Math.min(@strip_task, str.size)
          @strip_task -= drop
          str = str[drop..]
        end
        if @strip_alert > 0
          drop = Math.min(@strip_alert, str.size)
          @strip_alert -= drop
          str = str[drop..]
        end
        return if str.empty?
        pos = 0
        while p = str.index("~~", pos)
          ok = if @strike
                 p == 0 || !str[p - 1].whitespace?
               else
                 p + 2 >= str.size || !str[p + 2].whitespace?
               end
          unless ok # not a valid delimiter here: keep the tildes literal
            push_frag str[pos, p + 2 - pos]
            pos = p + 2
            next
          end
          push_frag str[pos...p]
          @strike = !@strike
          @fmt = nil
          pos = p + 2
        end
        push_frag str[pos..]
      end
    end

    # Blocks → markdown. Works purely off block/char structure: heading
    # levels, `code`-flagged runs over code-bg blocks (fences), the
    # quote-level/list/rule block properties, checkbox items (`[x]`/`[ ]`
    # from the list style + block `checked?`), and inline flags/anchors.
    private class Exporter
      # Items emitted so far per list instance (identity-keyed) — the
      # numbering source for ordered markers.
      @list_items = {} of UInt64 => Int32
      # Content column of the last item emitted per list depth — the indent
      # a nested list must reach to stay nested (CommonMark indents to the
      # parent item's content column, not a fixed 2).
      @item_cols = {} of Int32 => Int32

      # True when the block boundary before `blocks[i]` needs a blank
      # separator line: margins, rules, continuation paragraphs, and the
      # re-import guards — lazy continuation after a list item, ordered-list
      # interruption, table termination.
      # ameba:disable Metrics/CyclomaticComplexity
      private def separator_blank?(blocks : Array(TextBlock), i : Int32,
                                   pf : TextBlockFormat, cf : TextBlockFormat) : Bool
        # Paragraph spacing is block margins; any margin at the
        # boundary reads back as one blank line (markdown can't say
        # more). A rule block always gets one — `---` directly under
        # a paragraph line would re-parse as a setext heading.
        # A continuation paragraph (indent > 0, no list structure)
        # following a list item or another continuation needs a blank
        # line so CommonMark reads it as an indented continuation
        # rather than a lazy line that merges into the item.
        cont = cf.indent > 0 && cf.list_format.nil? &&
               (pf.list_format || (pf.indent > 0 && pf.list_format.nil?))
        return true if pf.bottom_margin > 0 || cf.top_margin > 0 ||
                       cf.horizontal_rule? || cont
        # An html block (CommonMark types 1-6) re-imports its lines RAW,
        # and markd's type-6 "continue until a blank line" rule would
        # swallow a following structured block — "<div>\n# h" reads the
        # heading back as literal html text. Force a blank line unless the
        # follower is a plain body paragraph at the *same* quote level:
        # that run re-imports as one html_block and re-splits 1:1.
        # A quote-level mismatch still needs the blank — write_block adds a
        # per-level "> " prefix that plain_body? doesn't account for, so a
        # bare newline would leak the quote marker into the html block on
        # re-import.
        return true if html_blockish?(blocks[i - 1]) && !html_blockish?(blocks[i]) &&
                       (!plain_body?(blocks[i]) || cf.quote_level != pf.quote_level)
        # A plain body paragraph directly after a list item (or a
        # list-continuation paragraph) at the same quote level would be
        # read as a lazy continuation of the item and merge into it on
        # re-import; force a blank line so it stays a standalone
        # paragraph.
        return true if cf.indent == 0 && plain_body?(blocks[i]) &&
                       pf.quote_level == cf.quote_level &&
                       (pf.list_format || (pf.indent > 0 && pf.list_format.nil?))
        # An ordered list item whose rendered number is not 1 cannot
        # interrupt a preceding paragraph — without a blank line it
        # lazily merges into that paragraph on re-import. The number is
        # `start + count-so-far`, read before write_block increments the
        # counter, so it equals the number about to render.
        if (clf = cf.list_format) && clf.style.numbered? &&
           plain_body?(blocks[i - 1]) &&
           clf.start + (@list_items[clf.object_id]? || 0) != 1
          return true
        end
        # A non-table block — or a second, distinct table — directly
        # after a table run would be swallowed as a data row by the GFM
        # table detector on re-import; force a blank line to end the
        # table.
        return true if (ptf = pf.table_format) && !ptf.same?(cf.table_format)
        # An empty list item after a plain paragraph renders as a bare
        # marker ("1. "); with only a newline it lazily merges into the
        # paragraph (an empty item can't interrupt a paragraph even with
        # number 1, so the numbered-!=1 guard above misses it).
        return true if cf.list_format && blocks[i].fragments.empty? &&
                       plain_body?(blocks[i - 1])
        # A table directly after a plain paragraph would be swallowed into
        # that paragraph on re-import (the GFM detector needs the table to
        # begin its own paragraph); force a blank line.
        return true if cf.table_format && pf.table_format.nil? &&
                       plain_body?(blocks[i - 1])
        false
      end

      def export(blocks : Array(TextBlock)) : String
        String.build do |io|
          i = 0
          while i < blocks.size
            if i > 0
              pf = blocks[i - 1].block_format
              cf = blocks[i].block_format
              blank = separator_blank?(blocks, i, pf, cf)
              # A quote-level decrease into a plain body paragraph leaves the
              # deeper quote's paragraph open, so a bare newline would lazily
              # continue it and merge the shallower block's text back in
              # (CommonMark lazy continuation). Break the run only when the
              # previous block leaves a continuable paragraph (plain body, a
              # list item, or a list-continuation paragraph): a ">"-only line
              # at the lower level when the target still sits in a quote (it
              # re-imports with no extra block), else a blank line at level 0.
              if !blank && pf.quote_level > cf.quote_level && plain_body?(blocks[i]) &&
                 (plain_body?(blocks[i - 1]) || pf.list_format ||
                 (pf.indent > 0 && pf.list_format.nil?))
                if cf.quote_level > 0
                  io << '\n' << ("> " * cf.quote_level).rstrip
                else
                  blank = true
                end
              end
              # Adjacent plain body blocks with no separating margin are a
              # hard break — a bare newline would soft-wrap them back into
              # one paragraph on re-import.
              io << '\\' if !blank && pf.quote_level == cf.quote_level &&
                            plain_body?(blocks[i - 1]) && plain_body?(blocks[i]) &&
                            !html_blockish?(blocks[i - 1]) && !html_blockish?(blocks[i])
              io << '\n'
              io << '\n' if blank
            end
            if opens_fence?(blocks, i)
              first = i
              fbf = blocks[first].block_format
              ql = fbf.quote_level
              prefix = "> " * ql
              # A fence that imported as list content must re-export inside its
              # item, else re-import detaches the code block from the list (and,
              # if the fence is the item's first content, drops the bullet and
              # shifts ordered numbering). Indent every fence/code line to the
              # item's content column: the item marker (when the fence is the
              # item's first block) or the continuation column (@item_cols keyed
              # by bf.indent // 2, mirroring write_block). Top-level and quoted
              # fences keep pad 0 and are unchanged.
              io << prefix
              pad =
                if lf = fbf.list_format
                  write_list_marker(io, lf, fbf.checked?)
                elsif fbf.indent > 0
                  col = @item_cols[fbf.indent // 2]? || fbf.indent
                  io << " " * col
                  col
                else
                  0
                end
              ticks = fence_ticks(blocks, first, ql)
              io << ticks << '\n'
              # The fence run ends at a margin or quote-level boundary —
              # two fences separated by a blank line stay two fences.
              while fence_member?(blocks, i, first, ql)
                io << prefix << " " * pad << blocks[i].text << '\n'
                i += 1
              end
              io << prefix << " " * pad << ticks
            elsif tf = blocks[i].block_format.table_format
              run = [] of TextBlock
              while i < blocks.size && blocks[i].block_format.table_format.same?(tf)
                run << blocks[i]
                i += 1
              end
              write_table(io, run, tf)
            else
              write_block(io, blocks[i], alert_open?(blocks, i))
              i += 1
            end
          end
        end
      end

      # A pre-rendered table run back to GFM: data rows (header first) with
      # a delimiter row from the table format's column alignments.
      private def write_table(io : IO, run : Array(TextBlock), tf : TextTableFormat) : Nil
        data = run.select { |b| TextTable.data_row?(b.text) }
        return if data.empty?
        prefix = "> " * run.first.block_format.quote_level
        # A literal `|` in a cell must not read back as a cell boundary,
        # and a literal `&` must not entity-decode on re-import.
        rows = data.map { |b| TextTable.split_data_row(b.text).map(&.gsub("|", "\\|").gsub("&", "\\&")) }
        io << prefix << "| " << rows[0].join(" | ") << " |"
        io << '\n' << prefix << '|'
        tf.columns.times do |c|
          io << ' ' << TextTable.gfm_delimiter(tf.alignments.try(&.[c]?)) << " |"
        end
        rows[1..].each do |cells|
          io << '\n' << prefix << "| " << cells.join(" | ") << " |"
        end
      end

      # A fenced-code row: block background set (the importer's code-bg
      # marker) and nothing but `code`-flagged fragments (or blank). A
      # blank styled block can only *continue* a fence, never open one
      # (*first*) — the fragment test is vacuous on an empty block.
      private def code_line?(b : TextBlock, first : Bool = false) : Bool
        return false unless b.block_format.bg
        return false if first && b.fragments.empty?
        b.fragments.all?(&.format.code?)
      end

      # Whether `blocks[k]` continues the fenced-code run that started at
      # *start* with quote level *ql*: a same-quote-level code line that is
      # either the run's first block or has no margin break from the previous
      # block. The single source of truth for where a fence run ends.
      private def fence_member?(blocks : Array(TextBlock), k : Int32, start : Int32, ql : Int32) : Bool
        k < blocks.size && code_line?(blocks[k]) &&
          blocks[k].block_format.quote_level == ql &&
          (k == start || (blocks[k].block_format.top_margin == 0 &&
            blocks[k - 1].block_format.bottom_margin == 0))
      end

      # The fence delimiter for the code run starting at *first*: one
      # backtick longer than the longest leading backtick run (≤ 3 spaces
      # indented — the only position CommonMark lets close a fence) on any
      # of the run's lines, so content that is itself a backtick run can't
      # close the fence early on re-import. `wrap_code`'s rule, per line;
      # minimum the standard 3.
      private def fence_ticks(blocks : Array(TextBlock), first : Int32, ql : Int32) : String
        run = 0
        j = first
        while fence_member?(blocks, j, first, ql)
          if len = blocks[j].text[/\A\s{0,3}(`+)/, 1]?.try(&.size)
            run = len if run < len
          end
          j += 1
        end
        "`" * Math.max(3, run + 1)
      end

      # Does the contiguous same-`bg`/quote-level run starting at *i* form a
      # fenced code block? A run opens a fence when it holds a real code line
      # (non-empty code fragments) or spans more than one line — so a code
      # block whose leading (or every) line is blank still fences at its first
      # block, while a lone empty styled block does not.
      private def opens_fence?(blocks : Array(TextBlock), i : Int32) : Bool
        return false unless blocks[i].block_format.bg
        ql = blocks[i].block_format.quote_level
        j = i
        count = 0
        has_code = false
        while fence_member?(blocks, j, i, ql)
          count += 1
          has_code = true unless blocks[j].fragments.empty?
          j += 1
        end
        has_code || count > 1
      end

      # The CommonMark HTML-block start patterns of types 1-6 — the kinds
      # that interrupt a paragraph and re-import their lines RAW. Type 7 (a
      # lone complete tag, which cannot interrupt a paragraph) is excluded.
      # Sliced once here rather than allocating a fresh Array per
      # `html_blockish?` call.
      private HTML_BLOCK_OPEN_TYPES = Markd::Rule::HTML_BLOCK_OPEN[0, 6]

      # Does *b*'s text open a CommonMark HTML block of types 1-6 — the
      # kinds that interrupt a paragraph and re-import their lines RAW?
      # Mirrors markd's own start conditions (type 7, a lone complete tag,
      # cannot interrupt a paragraph and is excluded).
      private def html_blockish?(b : TextBlock) : Bool
        t = b.text
        t.starts_with?('<') &&
          HTML_BLOCK_OPEN_TYPES.any? { |re| t.matches?(re) }
      end

      # A plain paragraph body block — the kind a hard break may join to
      # its neighbor (no heading/list/table/rule/fence structure).
      private def plain_body?(b : TextBlock) : Bool
        bf = b.block_format
        return false if bf.heading_level > 0 || bf.horizontal_rule? ||
                        bf.list_format || bf.table_format || code_line?(b)
        !b.fragments.empty? && !rule?(b.text)
      end

      # Emits a list item's marker (bullet, ordered number, or checkbox) for
      # *lf* to *io* — indenting to the parent item's content column, advancing
      # @list_items for ordered numbering, and recording the item's own content
      # column in @item_cols. Returns that content column, where the item's
      # inline text (or a fenced code block that opens as the item's first
      # content) must align. Shared by write_block's list branch and the
      # exporter's fence branch so both position items identically.
      private def write_list_marker(io : IO, lf : TextListFormat, checked : Bool) : Int32
        # A nested item indents to the parent item's content column
        # (falling back to 2/level when the parent never appeared).
        pad = lf.indent > 1 ? (@item_cols[lf.indent - 1]? || (lf.indent - 1) * 2) : 0
        io << " " * pad
        marker =
          if lf.style.checkbox?
            checked ? "- [x] " : "- [ ] "
          else
            n = @list_items[lf.object_id]? || 0
            @list_items[lf.object_id] = n + 1
            lf.style.numbered? ? "#{lf.start + n}. " : "- "
          end
        io << marker
        # For a checkbox item the content column is right after "- " —
        # the "[x] " marker is item *content* to CommonMark.
        col = pad + (lf.style.checkbox? ? 2 : marker.size)
        @item_cols[lf.indent] = col
        col
      end

      # Whether `blocks[i]` opens a new GFM alert run — the block `#write_block`
      # must prefix with the `[!KIND]` title line: it carries an alert kind,
      # and either sits first or follows a block whose kind or quote level
      # differs (a fresh alert, not a continuation of the one above it, e.g.
      # the blank quote-interior separator between two alert paragraphs).
      private def alert_open?(blocks : Array(TextBlock), i : Int32) : Bool
        cf = blocks[i].block_format
        return false unless cf.alert_kind
        return true if i == 0
        pf = blocks[i - 1].block_format
        pf.alert_kind != cf.alert_kind || pf.quote_level != cf.quote_level
      end

      private def write_block(io : IO, b : TextBlock, open_alert : Bool = false) : Nil
        bf = b.block_format
        if bf.quote_level > 0
          # A content-less quote block — the blank separator line between two
          # quoted paragraphs — emits bare ">" lines with no trailing space:
          # the canonical GFM form the importer consumed, so round-trips stay
          # byte-stable. Mirrors the rstripped ">"-only continuation line in
          # `write_blocks`.
          blank = !open_alert && b.fragments.empty? && !bf.horizontal_rule? &&
                  bf.heading_level == 0 && !bf.list_format
          prefix = "> " * bf.quote_level
          io << (blank ? prefix.rstrip : prefix)
        end

        if open_alert && (kind = bf.alert_kind)
          io << TextMarkdown.alert_marker(kind)
          # Nothing else to write on a marker-only block (an alert whose
          # quote holds no other content) — the title line is the block.
          has_body = !b.fragments.empty? || bf.horizontal_rule? || bf.heading_level > 0 || bf.list_format
          return unless has_body
          io << '\n' << "> " * bf.quote_level
        end

        if bf.horizontal_rule?
          io << "---"
          return
        end

        if lf = bf.list_format
          write_list_marker(io, lf, bf.checked?)
          # A heading inside a list item ("- # Title", which the importer
          # merges into one block) re-emits its hashes as item *content* —
          # CommonMark allows a heading as list-item content, and dropping
          # them would silently downgrade the construct on every roundtrip.
          # Skipped for checkbox items: GFM does not parse "- [x] # h" as a
          # task-item heading (and the importer can't produce that combination
          # from markdown anyway).
          if !lf.style.checkbox? && (lvl = bf.heading_level) > 0
            io << "#" * lvl << ' '
          end
          write_inline(io, b.fragments, lead: true)
          return
        end

        if (lvl = bf.heading_level) > 0
          io << "#" * lvl << ' '
          write_inline(io, b.fragments)
          return
        end

        text = b.text
        if rule?(text)
          io << "---"
          return
        end

        # A list-item continuation paragraph imports with `indent > 0` and no
        # list structure; re-emit indentation to the enclosing item's content
        # column. The importer's `indent` is a 2/level approximation, but the
        # marker width — e.g. 3 for "1. " — is what CommonMark needs to keep the
        # paragraph inside the item rather than merging it.
        if bf.indent > 0
          pad = @item_cols[bf.indent // 2]? || bf.indent
          io << " " * pad
        end
        write_inline(io, b.fragments, lead: true)
      end

      # A thematic break: nothing but rule glyphs (or plain dashes, which
      # markdown reads as an HR anyway).
      private def rule?(text : String) : Bool
        return false if text.size < 3
        rule_char = Glyphs[Glyphs::Role::LineHorizontal, Glyphs::Tier::Unicode]
        text.each_char.all? { |c| c == rule_char || c == '-' }
      end

      # Fragments as inline markdown, skipping the first *skip* chars (the
      # structural prefixes handled above). *lead* marks the first fragment
      # as sitting at a line start, where leading block syntax (`- `, `# `,
      # `1. `, …) must be escaped or it re-parses as structure.
      private def write_inline(io : IO, frags : Array(TextFragment) | TextFragmentView, skip : Int32 = 0, lead : Bool = false) : Nil
        frags.each do |f|
          t = f.text
          if skip > 0
            d = Math.min(skip, t.size)
            skip -= d
            t = t[d..]
          end
          next if t.empty?
          fmt = f.format
          # The anchor outranks the code flag: a code span *inside* a link
          # keeps the link, with the span as the link text.
          if url = fmt.anchor_href
            io << '['
            if fmt.code?
              write_code_span(io, t, fmt)
            else
              write_emphasis(io, t, fmt)
            end
            io << "](" << encode_url(url) << ')'
          elsif fmt.code?
            write_code_span(io, t, fmt)
          else
            write_emphasis(io, t, fmt, lead: lead)
          end
          lead = false
        end
      end

      # Bold/italic/strike markers around escaped text. Underline, colors and
      # the other SGR flags have no markdown form and are dropped. Fragment-
      # edge whitespace moves *outside* the markers — `**bold **` is not
      # right-flanking and would re-import as literal asterisks.
      private def write_emphasis(io : IO, text : String, fmt : TextCharFormat, lead : Bool = false) : Nil
        em = fmt.bold? ? (fmt.italic? ? "***" : "**") : (fmt.italic? ? "*" : "")
        if em.empty? && !fmt.strike?
          io << escape_md(text, lead: lead)
          return
        end
        lstripped = text.lstrip
        head = text[0, text.size - lstripped.size]
        core = lstripped.rstrip
        io << head
        return if core.empty? # whitespace-only: no markers at all
        io << "~~" if fmt.strike?
        io << em << escape_md(core) << em
        io << "~~" if fmt.strike?
        io << lstripped[core.size..]
      end

      # A code span, carrying a strike flag as `~~` around the span (the
      # only emphasis with a form *outside* a code span that this importer
      # reads back onto it).
      private def write_code_span(io : IO, text : String, fmt : TextCharFormat) : Nil
        io << "~~" if fmt.strike?
        io << wrap_code(text)
        io << "~~" if fmt.strike?
      end

      # A code span whose delimiter is one backtick longer than the longest
      # backtick run in the text (padded — the pad strips on re-import).
      private def wrap_code(text : String) : String
        longest = run = 0
        text.each_char do |c|
          if c == '`'
            run += 1
            longest = run if run > longest
          else
            run = 0
          end
        end
        ticks = "`" * (longest + 1)
        # Pad when a strip on re-import will fire: always when the text carries
        # a backtick, and for backtick-free text only when it has an edge space
        # AND a non-space char (markd strips one edge space per side only then).
        needs_pad = longest > 0 || ((text.starts_with?(' ') || text.ends_with?(' ')) && text.matches?(/[^ ]/))
        needs_pad ? "#{ticks} #{text} #{ticks}" : "`#{text}`"
      end

      # Percent-encodes the characters that break a bare CommonMark link
      # destination: whitespace, parentheses (unbalanced ones end the
      # link), angle brackets and control chars.
      private def encode_url(url : String) : String
        return url unless url.matches?(/[\s()<>\x00-\x1f]/)
        String.build do |io|
          url.each_char do |c|
            if c.ascii_whitespace? || c.in?('(', ')', '<', '>') || c.control?
              c.to_s.each_byte { |b| io << '%' << b.to_s(16, upcase: true).rjust(2, '0') }
            else
              io << c
            end
          end
        end
      end

      private def escape_md(text : String, lead : Bool = false) : String
        # `&` is escaped so entity-shaped plain text ("&amp;", "&#65;")
        # isn't decoded — and thereby mutated — on re-import.
        if text.matches?(/[\\`*_\[\]~&]/)
          text = text.gsub(/([\\`*_\[\]~&])/) { "\\#{$1}" }
        end
        return text unless lead
        # Block-leading syntax the inline class above doesn't cover: bullet
        # `-`/`+`, heading `#`, quote `>`, setext `=`, ordered `1.`/`1)`.
        if md = text.match(/\A(\s{0,3})([-+>#=|])/)
          text = "#{md[1]}\\#{md[2]}#{text[md[0].size..]}"
        elsif md = text.match(/\A(\s{0,3}\d{1,9})([.)])/)
          text = "#{md[1]}\\#{md[2]}#{text[md[0].size..]}"
        end
        text
      end
    end
  end

  class TextDocument
    # Builds a document from markdown.
    def self.from_markdown(text : String, theme : TextTheme = TextTheme.default) : TextDocument
      doc = TextDocument.new
      doc.set_markdown(text, theme)
      doc
    end

    # Replaces the whole content from markdown (Qt `setMarkdown`). Same reset
    # semantics as `set_plain_text` (not undoable, cursors rewind).
    #
    # Any `<!-- toc -->` region the source carried is regenerated from the
    # freshly imported outline — a load is the one moment there is no reader
    # position to disturb, so it is safe to refresh without being asked.
    def set_markdown(text : String, theme : TextTheme = TextTheme.default) : Nil
      replace_content(TextMarkdown.parse(text, theme))
      refresh_tocs(theme)
    end

    # `=`-setter spelling of `#set_markdown` (default theme; use `#set_markdown`
    # for an explicit one).
    def markdown=(text : String) : Nil
      set_markdown(text)
    end

    # The content as markdown (Qt `toMarkdown`).
    def to_markdown : String
      TextMarkdown.generate(blocks_mut)
    end

    # The per-document `TextMarkdown::Stream` behind `#append_markdown`,
    # created on first use.
    @markdown_stream : TextMarkdown::Stream?

    # Streams markdown into the document: buffers *chunk* on the
    # pending tail and, once the tail contains complete constructs
    # (`TextMarkdown::Stream`'s release rules), parses only those and appends
    # the blocks at the document end — what is already in the document is
    # never re-parsed. A trailing incomplete construct — an unclosed code
    # fence, a table or paragraph still growing — stays pending for the next
    # chunk; `#flush_markdown` force-parses it at end of stream.
    #
    # Two properties hold:
    #
    # - Seam equality: any chunking of a markdown text (plus a final
    #   `#flush_markdown`) yields the same blocks as parsing it whole. The
    #   pending-tail rules put every seam on a blank line no construct
    #   crosses, and the blank a seam consumes re-lands as the appended
    #   piece's first-block `top_margin` — exactly where one-shot import puts
    #   it. (Exception: a link reference definition resolves only within one
    #   released piece; see `TextMarkdown::Stream`.)
    # - Inline TOCs are NOT refreshed (contrast `#set_markdown`): an append is
    #   precisely the mid-stream case the manual-refresh policy
    #   protects the reader from. Call `#refresh_tocs` when the stream ends;
    #   a `TocView` sidebar tracks `ContentsChanged` on its own either way.
    #
    # The first piece released into an empty document adopts `#set_markdown`'s
    # reset semantics; every later piece is an ordinary undoable insertion
    # (one undo step per released piece).
    def append_markdown(chunk : String, theme : TextTheme = TextTheme.default) : Nil
      stream = (@markdown_stream ||= TextMarkdown::Stream.new)
      stream.append(chunk).try { |piece| append_markdown_piece(piece, theme) }
    end

    # Parses and appends whatever `#append_markdown` still holds pending — the
    # end-of-stream signal. A pure-whitespace tail parses to nothing and is
    # dropped. No-op when nothing is pending.
    def flush_markdown(theme : TextTheme = TextTheme.default) : Nil
      @markdown_stream.try(&.flush).try { |piece| append_markdown_piece(piece, theme) }
    end

    # Parses one released piece and appends its blocks at the document end.
    private def append_markdown_piece(text : String, theme : TextTheme) : Nil
      parsed = TextMarkdown.parse(text, theme)
      # An empty document adopts the piece wholesale — `#set_markdown`'s reset
      # semantics, minus the TOC refresh (manual for appends).
      if size == 0
        replace_content(parsed)
        return
      end
      # The seam always sits on a blank line, which one-shot import turns
      # into a `top_margin` on the following structure's first block
      # (`take_margin`). Replicate it — except onto a folded empty-TOC block,
      # whose format one-shot builds via `TextToc.context_format`, which
      # drops margins.
      first = parsed[0]
      unless first.size == 0 && first.block_format.frame_formats.try(&.any?(TextTocFormat))
        first.block_format = first.block_format.merge(TextBlockFormat.new(top_margin: 1))
      end
      # Appending must create new blocks, not merge `first` into the current
      # last block — `raw_insert_fragment` merges a fragment's first block
      # into the block at the insertion point. Ride behind an empty sentinel
      # carrying the last block's format: the sentinel merges into that block
      # (a no-op) and every parsed block materializes after it.
      sentinel = TextBlock.new("", TextCharFormat.default, blocks.last.block_format)
      insert_fragment(size, TextDocumentFragment.new([sentinel] + parsed))
    end
  end

  class TextDocumentFragment
    # Builds a detached fragment from markdown.
    def self.from_markdown(text : String, theme : TextTheme = TextTheme.default) : TextDocumentFragment
      new(TextMarkdown.parse(text, theme))
    end

    # The fragment as markdown.
    def to_markdown : String
      TextMarkdown.generate(@blocks)
    end
  end
end
