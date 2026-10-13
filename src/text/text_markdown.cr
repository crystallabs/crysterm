require "markd"

module Crysterm
  # Markdown import/export for `TextDocument` — the
  # `QTextDocument::setMarkdown`/`toMarkdown` counterpart. Import walks the
  # `markd` CommonMark AST straight into blocks/fragments (no tag-string
  # intermediate); export walks blocks back to markdown, keying on *semantic*
  # properties (`heading_level`, `code_language`, `TextCharFormat#code?`,
  # `anchor_href`) — the importer stores no colors; a view supplies them from
  # its style (`ContentPalette`).
  #
  # Mapping:
  #
  # - Headings → `TextBlockFormat#heading_level` (the view colors them).
  # - `**`/`*`/`~~`/backticks/links → char formats (`code` spans, anchors);
  #   images degrade to a `dim` placeholder glyph plus their alt text. A
  #   paragraph that is nothing but one image (a link around it allowed) is
  #   a *block image* besides: its block records the source, alt text and
  #   title (`TextBlockFormat#image`), a view that draws images puts the
  #   picture above the text (`Widget::TextEdit#images_enabled?`), and the
  #   exporter writes `![alt](src "title")` back.
  # - Paragraph spacing → `TextBlockFormat#top_margin` on the block that
  #   follows (the margins re-base; exporters read the margins back as blank
  #   lines, and HTML carries them as `margin-*` styles, so the formats stay
  #   cross-convertible). Spacing *interior* to a quote (a heading or code
  #   fence inside a blockquote) stays a literal quote-level separator block —
  #   it is quoted content and renders the quote bar. A hard line break
  #   starts a new block with neither.
  # - Whitespace inside a paragraph, heading, item or cell collapses as a
  #   browser renders it: runs of spaces and tabs to one space, a soft line
  #   break to a space. Code spans, code blocks and raw HTML blocks keep
  #   theirs.
  # - Lists → one `TextList` per markdown list (disc/decimal style, nesting
  #   via `TextListFormat#indent`); the widget renders markers/indent as
  #   decorations. An item's continuation blocks get a plain block indent
  #   approximation. A GFM task list (any item with `[x]`/`[ ]`) becomes a
  #   `Checkbox`-style list; each item's checked state rides on its block
  #   (`TextBlockFormat#checked?`), and the marker renders as `[x]`/`[ ]`.
  # - Blockquotes → `TextBlockFormat#quote_level`; thematic breaks → an
  #   empty `horizontal_rule` block.
  # - Fenced code → one block per line, `code`-flagged fragments on a
  #   `code_language` block (the exporter's fence detector; the info string
  #   is kept and re-emitted).
  # - Every block built from a source line records it (`TextBlock#source_line`,
  #   1-based): a paragraph's or heading's first line, each line of a code or
  #   HTML block, each hard-broken line, each table row. Generated blocks
  #   (separators, table borders, TOC entries) carry none. A streamed
  #   document (`TextDocument#append_markdown`) numbers lines over the whole
  #   stream, not per chunk.
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
    def self.parse(text : String) : Array(TextBlock)
      # `source_pos` records each block's source line/column so the importer
      # can tell a real `[x]` task marker from an escaped `\[x\]` one — markd
      # resolves the escape before the AST, so the text nodes are identical.
      #
      # markd's `gfm` option stays off on purpose: the importer detects
      # tables, task lists, alerts, `~~` strike and bare-URL autolinks
      # itself. With `gfm: true`,
      # markd (0.6.0) lets any paragraph line that merely contains a `|`
      # (`a|b`, `{|}`) open a table block that then degrades to a separate
      # paragraph, splitting ordinary prose in two — which github.com does
      # not do. Its checkbox rule also accepts only lowercase `[x]`.
      blocks = parse_piece(text)
      blocks.empty? ? [TextBlock.new] : blocks
    end

    # `.parse` without the empty block that stands in for a text holding no
    # block at all (blank lines, or only constructs that import to nothing,
    # such as an empty blockquote `>`). A document needs that block; a piece
    # `TextDocument#append_markdown` adds to one does not — appended, it
    # would be a blank line the whole text never had.
    def self.parse_piece(text : String) : Array(TextBlock)
      doc = Markd::Parser.parse(text, Markd::Options.new(source_pos: true))
      fold_tocs(Importer.new(text).import(doc))
    end

    # The line `.seam?` appends to the text before a proposed seam: so deeply
    # indented that whatever is still open there and can run on across a
    # blank line — a fence, an HTML block of types 1-5, a list item at any
    # nesting depth, indented code — takes it in, while after anything closed
    # it opens an indented code block of its own.
    private SEAM_PROBE = "#{" " * 100}x\n"
    # That code block's text when the probe line does start one.
    private SEAM_PROBE_CODE = "#{" " * 96}x\n"

    # Whether *prefix*, a text ending just past a blank line, can be parsed on
    # its own exactly as it parses at the head of any longer text — the
    # check `Stream` puts every release point it proposes through. Its line
    # scanner tracks fences and HTML blocks without the container context
    # markd has, so it can take a line inside one construct for the opening
    # of another (`<script>` inside an HTML block of type 7 for a block of
    # type 1, whose close then ends nothing while a real fence is still
    # open); markd's own parse of the prefix plus `SEAM_PROBE` settles it.
    # The prefix must also leave no `<!-- toc -->` waiting for its tocstop,
    # which the importer would pair across the seam (`.fold_tocs`) — that
    # opener can come out of any block, an HTML block's line or a code line
    # included, so the fold itself is asked.
    protected def self.seam?(prefix : String) : Bool
      text = prefix + SEAM_PROBE
      doc = Markd::Parser.parse(text, Markd::Options.new(source_pos: true))
      last = doc.last_child?
      return false unless last && last.type.code_block? && !last.fenced? && last.text == SEAM_PROBE_CODE
      return true unless prefix.matches?(/toc/i)
      fold_tocs(Importer.new(text).import(doc)).none? { |b| fence_open?(b) }
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
    # This class is text chunking: `TextDocument#append_markdown` owns one
    # per document and feeds the released pieces through `.parse_piece`.
    #
    # A line scanner proposes the release points below, and markd confirms
    # each before it is used (`TextMarkdown.seam?`): the scanner sees lines
    # without the containers around them, so it can mistake one construct's
    # content for another's opening, and a seam it alone vouched for could
    # fall inside a fence the scanner never saw open.
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

      # The 1-based line, counted over everything released so far, that the
      # piece `#append` or `#flush` last returned starts on: what a consumer
      # adds (minus one) to the piece-relative `TextBlock#source_line`s the
      # parser stamps, so a streamed document's lines are the whole stream's.
      getter piece_line = 1
      # Lines (`'\n'`s) released so far.
      @released_lines = 0

      # Byte offset into `@pending` of the first unscanned byte; only whole
      # `'\n'`-terminated lines are ever classified.
      @scan_pos = 0
      # Byte offsets of the release points the scan proposes (each just past
      # a blank line), in order; `#release` takes the last one markd
      # confirms (`TextMarkdown.seam?`).
      @boundaries = [] of Int32
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
        @piece_line = @released_lines + 1
        @released_lines += rest.count('\n')
        rest.each_char.any? { |c| !c.in?(' ', '\t', '\r', '\n') } ? rest : nil
      end

      private def reset : Nil
        @pending = ""
        @scan_pos = 0
        @boundaries.clear
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

      # Cuts the pending buffer at the last proposed boundary markd confirms,
      # rebasing the scan state (all offsets are byte-based; a boundary lies
      # just past a `'\n'`, so the cut is always on a character boundary).
      # A boundary markd rejects stays rejected — the verdict depends only on
      # the text before it — so every proposal is dropped here either way.
      private def release : String?
        b = @boundaries.reverse_each.find { |c| TextMarkdown.seam?(@pending.byte_slice(0, c)) }
        @boundaries.clear
        return unless b
        piece = @pending.byte_slice(0, b)
        @pending = @pending.byte_slice(b, @pending.bytesize - b)
        @scan_pos -= b
        @last_content_end = Math.max(@last_content_end - b, 0)
        @piece_line = @released_lines + 1
        @released_lines += piece.count('\n')
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
          @boundaries << line_end if @last_content_end > 0 && !@unsafe_tail && !@toc_open
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
      # The source line (1-based, from `source_pos`) the text being imported
      # comes from: set when a block-level node is entered and advanced by
      # the line breaks inside a paragraph. `start_block` captures it as the
      # block's first line (`@block_line`), which `end_block` stamps onto the
      # block as `TextBlock#source_line` — so a soft-wrapped paragraph gets
      # its first line, a hard-broken continuation and a code block's n-th
      # line each their own.
      @line : Int32?
      @block_line : Int32?

      def initialize(source : String = "")
        @source = source.split('\n')
      end

      # The blocks *doc* imports to — none at all when it holds nothing
      # (`TextMarkdown.parse` supplies the empty block a document needs).
      def import(doc : Markd::Node) : Array(TextBlock)
        walk_children(doc)
        @blocks
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
          @line = source_line_of(node)
          start_block TextBlockFormat.new(heading_level: node.data["level"].as(Int32))
          walk_children(node)
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
          @line = source_line_of(node)
          start_block TextBlockFormat.new(horizontal_rule: true)
          end_block
        when .html_block?
          structure_separator
          first = source_line_of(node)
          node.text.chomp.split('\n').each_with_index do |line, i|
            @line = first + i
            start_block
            # Raw HTML shows as written, a `<pre>` block's spacing included.
            append_text line, collapse: false
            end_block
          end
        when .text?
          append_text node.text
        when .code?
          with_patch(TextCharFormat.new(code: true)) { push_frag node.text }
        when .strong?
          with_patch(TextCharFormat.new(bold: true)) { walk_children(node) }
        when .emphasis?
          with_patch(TextCharFormat.new(italic: true)) { walk_children(node) }
        when .link?
          url = node.data["destination"]?.try(&.as(String))
          with_patch(TextCharFormat.new(anchor_href: url)) { walk_children(node) }
        when .image?
          # No inline images on a cell grid: degrade to a picture-frame glyph
          # and the alt text. The glyph comes from the registry (so
          # `Glyphs.set` retheming and an ASCII-fied table apply) at the
          # `extended` tier — `🖼`, a text-presentation emoji of exactly one
          # column — rather than the `unicode` tier the rules and quote bars
          # above use: those must stay box-drawing to join borders, while the
          # placeholder is content, and the picture is what the emoji-capable
          # terminals this is read on draw. An importer has no screen to ask
          # for the effective tier. `dim` marks it muted for the view.
          with_patch(TextCharFormat.new(dim: true)) do
            push_frag "#{image_placeholder} "
            walk_children(node)
          end
        when .soft_break?
          append_text " "
          next_source_line
        when .line_break?
          # Hard break: new block in the same paragraph flow (no separator).
          # Inside a heading (a setext one, the only kind spanning lines) the
          # continuation stays a heading of the same level, as `<h2>a<br>b`
          # does through the HTML importer. Only the level carries over: the
          # rest of the format is the closed block's own (an image, a top
          # margin) or is stamped again by `start_block` (quote level).
          level = @block_format.heading_level
          end_block
          next_source_line
          start_block(level > 0 ? TextBlockFormat.new(heading_level: level) : TextBlockFormat.default)
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
        @line = source_line_of(node)
        # A table-shaped paragraph inside a list item stays ordinary item
        # content: import_table stamps no list membership, so taking the
        # table path there would detach it from the list and shift ordered
        # numbering (the exporter's lead escape keeps the `|` roundtrip
        # stable). Since the table path requires an empty list stack, check that
        # first, then screen on the raw source lines (`table_candidate?`), and
        # only build the full recursive `table_probe_text` for the rare
        # paragraph that passes both — never for the (common) list-nested or
        # ordinary prose paragraph.
        if @list_stack.empty? && table_candidate?(node) && (txt = table_probe_text(node)) && TextTable.gfm_table?(txt)
          import_table(txt)
          return
        end
        # A paragraph that is one image is a block image: the block carries
        # the image, and its text is the usual placeholder and alt text.
        img = sole_image(node)
        start_block(img ? TextBlockFormat.new(image: img) : TextBlockFormat.default)
        walk_children(node)
        end_block
      end

      # The image a paragraph *is*: its one child that is not whitespace is
      # an image — or a link holding exactly an image, the
      # `[![badge](src)](href)` idiom. An image among text is inline and
      # stays the placeholder glyph with the alt text, so `nil` then.
      private def sole_image(node : Markd::Node) : TextImageFormat?
        sole = sole_child(node) || return
        sole = sole_child(sole) || return if sole.type.link?
        return unless sole.type.image?
        title = sole.data["title"]?.try(&.as(String))
        TextImageFormat.new(
          name: sole.data["destination"]?.try(&.as(String)) || "",
          alt: alt_text(sole),
          title: title.presence)
      end

      # *node*'s one child besides whitespace (blank text, a soft break), or
      # `nil` when it has none or more than one.
      private def sole_child(node : Markd::Node) : Markd::Node?
        sole = nil
        child = node.first_child?
        while child
          case child.type
          when .soft_break?
          when .text? then return unless child.text.blank?
          else
            return if sole
            sole = child
          end
          child = child.next?
        end
        sole
      end

      # An image's alt text: its children's plain text on one line.
      private def alt_text(node : Markd::Node) : String
        String.build { |io| collect_text(node, io) }.gsub('\n', ' ').strip
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
        fmt = TextCharFormat.new(code: true)
        bf = TextBlockFormat.new(code_language: node.fence_language)
        # A fence's content starts on the line after the opening fence;
        # indented code starts on its own first line.
        first = source_line_of(node) + (node.fenced? ? 1 : 0)
        node.text.chomp.split('\n').each_with_index do |line, i|
          @line = first + i
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
        @blocks.last.source_line = @block_line
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
        bs = TextTable.build_from_gfm(txt) || return
        stamp_table_lines(bs)
        adopt_table_blocks(bs)
        if kind = @alert_stack.last?
          q = TextBlockFormat.new(alert_kind: kind)
          bs.each { |b| b.block_format = b.block_format.merge(q) }
        end
        @emitted = true
      end

      # Hook (`TextImport::Builder#after_start_block`): the block under
      # construction starts on the current source line.
      private def after_start_block(collapse : Bool) : Nil
        @block_line = @line
      end

      # The 1-based source line *node* starts on (`source_pos`; markd records
      # it for block-level nodes when parsing with `source_pos: true`).
      private def source_line_of(node : Markd::Node) : Int32
        node.source_pos[0][0]
      end

      # A line break inside a paragraph: the text that follows comes from the
      # next source line.
      private def next_source_line : Nil
        @line = @line.try &.+(1)
      end

      # Stamps a table's data rows with their source lines: the header on
      # the paragraph's first line, the body rows from the third on (the
      # delimiter row sits between and renders as no block). Border rows are
      # generated and get none.
      private def stamp_table_lines(bs : Array(TextBlock)) : Nil
        first = @line || return
        row = 0
        bs.each do |b|
          next unless TextTable.data_row?(b.text)
          b.source_line = first + row + (row > 0 ? 1 : 0)
          row += 1
        end
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

      # The tail of a GFM delimiter row (`|---|`, `:--:`, `--- | ---:`): the
      # `TextTable.gfm_table?` row shape, unanchored at the start so a
      # container prefix (`> `, indentation) before it doesn't matter.
      DELIMITER_TAIL = /\|?[\s:|-]*-[\s:|-]*\|?\s*\z/

      # Cheap screen before the table probe, on the paragraph's raw source
      # lines (`source_pos`) — no node serialization, no allocation. A GFM
      # table is a `|` header line followed by a delimiter row, and both are
      # judged on the raw lines by github.com too, so a paragraph whose first
      # source line has no pipe or whose second doesn't end in a delimiter
      # row can't be one. Almost every paragraph fails here, which is the
      # point: `#table_probe_text` serializes the whole inline subtree and
      # rescans the source for escapes, work worth doing only for a genuine
      # candidate. False positives (prose ending in ` -|`) just fall through
      # to the exact check.
      private def table_candidate?(node : Markd::Node) : Bool
        first, last = node.source_pos
        return false unless last[0] > first[0]
        return false unless (l0 = @source[first[0] - 1]?) && l0.includes?('|')
        return false unless (l1 = @source[first[0]]?) && l1.includes?('-')
        DELIMITER_TAIL.matches?(l1)
      end

      # `#node_text` of a paragraph with every backslash-escaped `\|` of the
      # source restored, for the GFM table probe and cell splitter — which
      # must read `\|` as cell content and a bare `|` as a boundary.
      #
      # markd resolves the escape before the AST, so a `\|` surfaces as a
      # plain `|` text node, indistinguishable there from an unescaped pipe
      # that markd split off alone because a neighbor is an inline special
      # (`|:---:|` — the `:` of an alignment delimiter — `|*a*|`, `|:tada:|`).
      # Guessing from node shape read every centered/right-aligned delimiter
      # row as escaped and demoted the whole table to a paragraph. So consult
      # the source instead: the paragraph's lines (`source_pos`, kept by
      # `#parse`) hold its pipes in the order `#collect_text` emits them, with
      # the escapes still visible. Container prefixes (`>`, list markers,
      # indentation) carry no pipes, so they don't shift the count.
      private def table_probe_text(node : Markd::Node) : String
        txt = node_text(node)
        esc = escaped_pipes(node)
        return txt unless esc.any?
        k = -1
        String.build do |io|
          txt.each_char do |ch|
            io << '\\' if ch == '|' && esc[k += 1]?
            io << ch
          end
        end
      end

      # Source whose pipes never reach `#collect_text`'s output and so must
      # not be counted against it: a link or image destination with its
      # title (`](url "title")`) and an inline HTML tag. An autolink keeps
      # its pipes — markd emits its URL as text. (Inline code is not set
      # apart: a `](` inside a code span is rare enough to leave.)
      SOURCE_ONLY_PIPES = /\]\([^)]*\)|<\/?[a-zA-Z][^>]*>/

      # For each `|` of *node*'s source lines that `#collect_text` emits, in
      # order, whether it is backslash-escaped (preceded by an odd run of
      # backslashes — `\\|` is an escaped backslash before a bare pipe).
      private def escaped_pipes(node : Markd::Node) : Array(Bool)
        first, last = node.source_pos
        flags = [] of Bool
        (first[0]..last[0]).each do |ln|
          next unless l = @source[ln - 1]?
          l = l.gsub(SOURCE_ONLY_PIPES, "") if l.includes?('(') || l.includes?('<')
          run = 0
          l.each_char do |ch|
            if ch == '\\'
              run += 1
              next
            end
            flags << run.odd? if ch == '|'
            run = 0
          end
        end
        flags
      end

      # The first *limit* **codepoints** of what `#collect_text` would produce
      # for *node* — same traversal, same emission order — stopping as soon as
      # that many are accumulated. For a caller that only
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
            n = append_bounded io, child.text, limit, n
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
          when .text?                     then io << child.text
          when .code?                     then io << child.text
          when .soft_break?, .line_break? then io << '\n'
          when .image?
            # The same degrade as the rich path (`walk_children`): the
            # picture-frame glyph, then the alt text — so a table cell holding
            # only an image shows the glyph rather than nothing.
            io << image_placeholder
            unless child.first_child?.nil?
              io << ' '
              collect_text child, io
            end
          else collect_text child, io
          end
          child = child.next?
        end
      end

      # What stands in for an inline image on the cell grid — see the
      # `image?` branch of `walk_children` for the choice of tier.
      private def image_placeholder : String
        Glyphs.str(Glyphs::Role::IconImage, Glyphs::Tier::Extended)
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

      # A bare URL in running text, as GFM's autolink extension sees one
      # (github.com turns it into a link without the `[]()` syntax): an
      # `http://`, `https://` or `www.` run at the start of the text or
      # after whitespace or one of `*_~(`, up to whitespace or `<`. What
      # the run ends with is trimmed afterwards (`.autolink_end`).
      AUTOLINK = /(?<![^\s*_~(])(?:https?:\/\/|www\.)[^\s<]+/i

      # Trailing punctuation GFM leaves out of an autolink.
      AUTOLINK_TRAIL = "?!.,:*_~"

      # Where an autolink match *run* really ends: without trailing
      # punctuation, a `)` that closes no `(` of its own, or an entity-like
      # `&…;` tail — repeatedly, as `https://x.io/a).` sheds both.
      def self.autolink_end(run : String) : Int32
        stop = run.size
        while stop > 0
          last = run[stop - 1]
          if AUTOLINK_TRAIL.includes?(last)
            stop -= 1
          elsif last == ')' && (kept = run[0, stop]) && kept.count(')') > kept.count('(')
            stop -= 1
          elsif last == ';' && (m = run[0, stop].match(/&[A-Za-z0-9]+;\z/))
            stop -= m[0].size
          else
            break
          end
        end
        stop
      end

      # A URL's host, for `AUTOLINK`: a dot somewhere before the path.
      AUTOLINK_HOST = /\A(?:https?:\/\/|www\.)[^\/]*\./i

      # A `www.`, in any case, as `AUTOLINK` matches it.
      WWW = /www\./i

      # Whether *url* starts with `WWW`.
      def self.www?(url : String) : Bool
        (m = WWW.match(url)) ? m.begin == 0 : false
      end

      # Whether a block's fragments can hold a bare URL at all: the `//` of a
      # scheme (which markd hands over as one node) or a `www.`; the cheap
      # gate before the runs are joined and scanned.
      private def autolink_candidate?(frags : Array(TextFragment)) : Bool
        frags.any? { |f| (t = f.text).includes?("//") || t.matches?(WWW) }
      end

      # Commits the block with its bare URLs linked (`#autolink_frags`).
      private def commit_block : Nil
        autolink_frags
        super
      end

      # Links the bare URLs of the block about to be committed. markd hands a
      # paragraph over as many small text nodes (`https://x` arrives as
      # `https`, `:`, `//`, `x`), so the fragments are read in runs of one
      # format, and a URL found in a run's text (`AUTOLINK`, its end by
      # `.autolink_end`) becomes a fragment of its own with the anchor
      # added — a `www.` one with `http://` before it, as github.com links
      # it. Code and text inside a link already are left alone.
      private def autolink_frags : Nil
        frags = @frags
        return if frags.empty? || !autolink_candidate?(frags)
        out = [] of TextFragment
        i = 0
        while i < frags.size
          fmt = frags[i].format
          j = i
          text = String.build do |io|
            while j < frags.size && frags[j].format == fmt
              io << frags[j].text
              j += 1
            end
          end
          if fmt.anchor_href || fmt.code? || !text.matches?(AUTOLINK)
            (i...j).each { |k| out << frags[k] }
          else
            # The run before this one — a code span, a link's text, an
            # image — must leave the URL free-standing too, as the raw
            # byte before it does for GFM: `` `c`https://x.io `` is no link.
            before = i > 0 ? frags[i - 1].text[-1]? : nil
            pos = 0
            text.scan(AUTOLINK) do |m|
              run = m[0]
              next if m.begin == 0 && before && !(before.whitespace? || "*_~(".includes?(before))
              stop = Importer.autolink_end(run)
              next if stop == 0 || !run[0, stop].matches?(AUTOLINK_HOST)
              out << TextFragment.new(text[pos...m.begin], fmt) if m.begin > pos
              url = run[0, stop]
              href = Importer.www?(url) ? "http://#{url}" : url
              out << TextFragment.new(url, fmt.merge(TextCharFormat.new(anchor_href: href)))
              pos = m.begin + stop
            end
            out << TextFragment.new(text[pos..], fmt) if pos < text.size
          end
          i = j
        end
        @frags = out
      end

      # Emits literal text: drops a pending task-marker prefix, collapses the
      # whitespace (unless *collapse* is off — a raw HTML block's lines go in
      # as written) and treats `~~` as a strike toggle (markd leaves `~`
      # literal, and splits backslash-escaped `\~` into single-char text
      # nodes — those never form a `~~` here, so escapes stay literal).
      # GFM-ish flanking: an opener can't precede whitespace, a closer can't
      # follow it; a delimiter at a node edge pairs across sibling inline
      # nodes.
      private def append_text(str : String, collapse : Bool = true) : Nil
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
        str = collapse_spaces(str) if collapse
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

      # Runs of spaces and tabs in a paragraph line — CommonMark leaves them
      # in the text and expects the renderer to collapse them, as a browser
      # does for the HTML renderers' output. A soft break arrives here as a
      # space too (`walk`), so a wrapped line joins its successor with one.
      SPACE_RUN = /[ \t]+/

      # *str* with its whitespace collapsed the way a browser renders a
      # paragraph: every run of spaces and tabs becomes one space, and a
      # space that would open the block or follow one already emitted (by
      # the preceding inline node — `**a**   b` arrives as `a` and `   b`)
      # is dropped. Code spans and code blocks bypass this (`push_frag` and
      # `import_code_block` take their text as is), and markd has already
      # trimmed the paragraph's and each line's ends.
      private def collapse_spaces(str : String) : String
        s = str.gsub(SPACE_RUN, ' ')
        s = s.lchop(' ') if s.starts_with?(' ') && boundary_space?
        s
      end

      # Whether a leading space would be redundant here: nothing emitted in
      # the block yet, or the previous run already ends in one.
      private def boundary_space? : Bool
        last = @frags.last?
        last.nil? || last.text.ends_with?(' ')
      end
    end

    # Blocks → markdown. Works purely off block/char structure: heading
    # levels, `code`-flagged runs on `code_language` blocks (fences), the
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

      # ameba:disable Metrics/CyclomaticComplexity
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
              if blank && cf.quote_level > 0 && pf.quote_level == cf.quote_level &&
                 cf.indent > 0 && cf.list_format.nil? && cf.top_margin == 0 && pf.bottom_margin == 0
                # A list item's later block inside a quote (`> - a\n>\n>   ## H`):
                # the blank line keeps the quote's `>`, or it would end the
                # quote and the block would land in a second one.
                io << ("> " * cf.quote_level).rstrip << '\n'
              elsif blank
                io << '\n'
              end
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
              io << ticks << (fbf.code_language || "") << '\n'
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
        rows = data.map { |b| TextTable.row_cells(b).map(&.gsub("|", "\\|").gsub("&", "\\&")) }
        io << prefix << "| " << rows[0].join(" | ") << " |"
        io << '\n' << prefix << '|'
        tf.columns.times do |c|
          io << ' ' << TextTable.gfm_delimiter(tf.alignments.try(&.[c]?)) << " |"
        end
        rows[1..].each do |cells|
          io << '\n' << prefix << "| " << cells.join(" | ") << " |"
        end
      end

      # A fenced-code row: a `code_language` block (the importer's marker)
      # holding nothing but `code`-flagged fragments (or blank). A blank code
      # block can only *continue* a fence, never open one (*first*) — the
      # fragment test is vacuous on an empty block.
      private def code_line?(b : TextBlock, first : Bool = false) : Bool
        return false unless b.block_format.code_block?
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

      # Does the contiguous code-block/quote-level run starting at *i* form a
      # fenced code block? A run opens a fence when it holds a real code line
      # (non-empty code fragments) or spans more than one line — so a code
      # block whose leading (or every) line is blank still fences at its first
      # block, while a lone empty styled block does not.
      private def opens_fence?(blocks : Array(TextBlock), i : Int32) : Bool
        return false unless blocks[i].block_format.code_block?
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

      # ameba:disable Metrics/CyclomaticComplexity
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
          # A rule inside a list item (`- ***`, or `***` at a continuation's
          # column) stays in the item. It is written `***`: `- ---` is one
          # thematic break to CommonMark (the marker's `-` joins the rule),
          # and an indented `---` under the item's text would underline it
          # into a setext heading.
          if lf = bf.list_format
            write_list_marker(io, lf, bf.checked?)
            io << "***"
          elsif bf.indent > 0
            io << " " * (@item_cols[bf.indent // 2]? || bf.indent) << "***"
          else
            io << "---"
          end
          return
        end

        # A block image goes back as the image it was read from — inside the
        # link its text carries, when it does (`[![alt](src)](href)`); its
        # text is only the stand-in. In a list it sits behind the item's
        # marker or at a continuation's column, like a paragraph there.
        if img = bf.image
          if lf = bf.list_format
            write_list_marker(io, lf, bf.checked?)
          elsif bf.indent > 0
            io << " " * (@item_cols[bf.indent // 2]? || bf.indent)
          end
          href = b.fragments.first?.try(&.format.anchor_href)
          io << '[' if href
          write_image(io, img)
          io << "](" << encode_url(href) << ')' if href
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
          # A heading that is a later block of a list item (`- a\n\n  ## H`)
          # imports with the continuation indent and no list; it goes back at
          # the item's content column, as a continuation paragraph does, or
          # it would leave the list.
          io << " " * (@item_cols[bf.indent // 2]? || bf.indent) if bf.indent > 0
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

      # `![alt](src "title")`: the alt text escaped as inline text is, the
      # destination in angle brackets when it holds a space or a parenthesis
      # (CommonMark's form for one), the title quoted when there is one.
      private def write_image(io : IO, img : TextImageFormat) : Nil
        io << "![" << escape_md(img.alt) << "]("
        name = decode_utf8_escapes(img.name)
        if name.includes?(' ') || name.includes?('(') || name.includes?(')')
          io << '<' << name.gsub('<', "\\<").gsub('>', "\\>") << '>'
        else
          io << name
        end
        if title = img.title
          io << " \"" << title.gsub('"', "\\\"") << '"'
        end
        io << ')'
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
        frags.each_with_index do |f, i|
          t = f.text
          if skip > 0
            d = Math.min(skip, t.size)
            skip -= d
            t = t[d..]
          end
          next if t.empty?
          fmt = f.format
          # The anchor outranks the code flag: a code span *inside* a link
          # keeps the link, with the span as the link text. A link that is
          # its own URL went in as a bare one (`Importer::AUTOLINK`) and
          # comes out as one, unescaped — where the text around it lets a
          # bare URL be read as one (`#bare_context?`); `[u](u)` would not be
          # what was read.
          if (url = fmt.anchor_href) && autolink?(t, url, fmt) && bare_context?(frags, i)
            io << t
          elsif url
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

      # Whether a fragment *text* linked to *url* is a bare URL the importer
      # autolinked: the plain, unformatted URL itself, or a `www.` one with
      # the `http://` the importer put before it.
      private def autolink?(text : String, url : String, fmt : TextCharFormat) : Bool
        return false if fmt.code? || fmt.bold? || fmt.italic? || fmt.strike?
        return false unless Importer.www?(text) ? url == "http://#{text}" : text == url
        m = text.match(Importer::AUTOLINK) || return false
        m.begin == 0 && m.end == text.size && Importer.autolink_end(text) == text.size && text.matches?(Importer::AUTOLINK_HOST)
      end

      # Whether fragment *i* of *frags*, written bare, would be read back as
      # the URL it is: what comes before it is nothing, whitespace or one of
      # the characters `Importer::AUTOLINK` lets precede a URL, and what
      # follows is nothing, whitespace, or closing parentheses and punctuation
      # the import trims off a URL's end (`Importer::AUTOLINK_TRAIL`) up to
      # whitespace — not text that would join the URL (`https://x.iomore`,
      # `https://x.io).com`) or keep it from being one (`see:https://y.io`).
      private def bare_context?(frags : Array(TextFragment) | TextFragmentView, i : Int32) : Bool
        before = i > 0 ? frags[i - 1].text[-1]? : nil
        return false unless before.nil? || before.whitespace? || "*_~(".includes?(before)
        following = frags[i + 1]?.try(&.text) || return true
        # What the import would trim off the URL's end may follow, but only
        # up to whitespace: `https://x.io).com` would read as one URL.
        rest = following.lstrip(")#{Importer::AUTOLINK_TRAIL}")
        rest.empty? || rest[0].whitespace?
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
      # link), angle brackets and control chars. Escapes of non-ASCII
      # characters are written back as the characters first
      # (`#decode_utf8_escapes`).
      private def encode_url(url : String) : String
        url = decode_utf8_escapes(url)
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

      # A run of percent-escapes of bytes 0x80 and up — what a non-ASCII
      # character is in a destination markd has normalized.
      HIGH_ESCAPES = /(?:%[89A-Fa-f][0-9A-Fa-f])+/

      # *url* with the percent-escapes that spell non-ASCII UTF-8 written as
      # the characters: markd percent-encodes every non-ASCII byte of a link
      # or image destination at parse time, so an author's `ćevapi.png`
      # would otherwise come back as `%C4%87evapi.png`. The two are one URL
      # (markd encodes `ć` to exactly those escapes on the way back in, so
      # the destination re-imports byte for byte), which also makes a
      # destination the author wrote as `%C4%87` come back as `ć` — the same
      # URL in its readable form. Escapes of ASCII bytes stay (a `%20` is a
      # space, a `%25` a percent sign, and either decoded changes or breaks
      # the destination), as do a run that is not valid UTF-8 and the
      # characters that are invisible or unsafe to read raw: Unicode
      # whitespace (a no-break space) and control, format and unassigned
      # characters (a bidi override, a zero-width space).
      private def decode_utf8_escapes(url : String) : String
        return url unless url.includes?('%')
        url.gsub(HIGH_ESCAPES) do |run|
          decoded = String.new(Bytes.new(run.size // 3) { |k| run[k * 3 + 1, 2].to_u8(16) })
          next run unless decoded.valid_encoding?
          String.build do |io|
            decoded.each_char do |c|
              if c.whitespace? || c.control?
                c.to_s.each_byte { |b| io << '%' << b.to_s(16, upcase: true).rjust(2, '0') }
              else
                io << c
              end
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
    def self.from_markdown(text : String) : TextDocument
      doc = TextDocument.new
      doc.set_markdown(text)
      doc
    end

    # Replaces the whole content from markdown (Qt `setMarkdown`). Same reset
    # semantics as `set_plain_text` (not undoable, cursors rewind). Returns
    # the assigned text.
    #
    # Any `<!-- toc -->` region the source carried is regenerated from the
    # freshly imported outline — a load is the one moment there is no reader
    # position to disturb, so it is safe to refresh without being asked.
    def set_markdown(text : String) : String
      replace_content(TextMarkdown.parse(text))
      refresh_tocs
      text
    end

    # `=`-setter spelling of `#set_markdown` (use
    # `#set_markdown` for an explicit one).
    def markdown=(text : String) : String
      set_markdown(text)
    end

    # The content as markdown (Qt `toMarkdown`).
    def to_markdown : String
      TextMarkdown.generate(blocks_mut)
    end

    # The per-document `TextMarkdown::Stream` behind `#append_markdown`,
    # created on first use.
    @markdown_stream : TextMarkdown::Stream?
    # The document's last block as `#append_markdown` left it after its
    # latest piece: the mark that an empty-looking document is the stream's
    # own output (a lone rule, an empty TOC frame or code block holds no
    # characters) and not a document still waiting for its first piece.
    @markdown_tail : TextBlock?

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
    def append_markdown(chunk : String) : Nil
      stream = (@markdown_stream ||= TextMarkdown::Stream.new)
      stream.append(chunk).try { |piece| append_markdown_piece(piece, stream.piece_line) }
    end

    # Parses and appends whatever `#append_markdown` still holds pending — the
    # end-of-stream signal. A pure-whitespace tail parses to nothing and is
    # dropped. No-op when nothing is pending.
    def flush_markdown : Nil
      stream = @markdown_stream || return
      stream.flush.try { |piece| append_markdown_piece(piece, stream.piece_line) }
    end

    # Parses one released piece and appends its blocks at the document end.
    # *line* is the piece's first line within the whole stream: the parser
    # numbers `TextBlock#source_line` from 1 per piece, so the blocks are
    # rebased onto it.
    private def append_markdown_piece(text : String, line : Int32 = 1) : Nil
      # A piece that imports to no block at all (an empty blockquote, say)
      # adds none: one-shot import has no block for it either.
      parsed = TextMarkdown.parse_piece(text)
      return if parsed.empty?
      parsed.each { |b| b.source_line = b.source_line.try &.+(line - 1) } if line > 1
      # An empty document adopts the piece wholesale — `#set_markdown`'s reset
      # semantics, minus the TOC refresh (manual for appends). Empty means
      # holding no characters *and* not being what the previous piece left:
      # a first piece of content-less blocks (a rule, an empty TOC) leaves the
      # size at 0 too, and the next piece must append behind them, not
      # replace them.
      if size == 0 && !blocks.last.same?(@markdown_tail)
        replace_content(parsed)
        @markdown_tail = blocks.last
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
      # At an empty last block the sentinel *is* that block (the fragment's
      # head block's format and stamp replace the target's at a block
      # start), so it carries the block's source line too, or the stamp
      # would be lost.
      last = blocks.last
      sentinel = TextBlock.new("", TextCharFormat.default, last.block_format)
      sentinel.source_line = last.source_line
      insert_fragment(size, TextDocumentFragment.new([sentinel] + parsed))
      @markdown_tail = blocks.last
    end
  end

  class TextDocumentFragment
    # Builds a detached fragment from markdown.
    def self.from_markdown(text : String) : TextDocumentFragment
      new(TextMarkdown.parse(text))
    end

    # The fragment as markdown.
    def to_markdown : String
      TextMarkdown.generate(@blocks)
    end

    # Alias for `#to_markdown` — the bare-reader spelling the document also
    # has.
    def markdown : String
      to_markdown
    end
  end
end
