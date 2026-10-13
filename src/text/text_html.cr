require "html5"
require "./html_node_util"
require "./text_align"

module Crysterm
  # HTML-subset import/export for `TextDocument` — the
  # `QTextDocument::setHtml`/`toHtml` counterpart, parsed with the `html5` shard.
  #
  # Supported on import: `p div h1..h6 b/strong i/em u/ins s/strike/del a[href]
  # img[src alt title] br hr ul ol li pre code/tt/kbd/samp blockquote
  # span[style] font[color]`,
  # plus the style properties `color`, `background(-color)`, `font-weight`,
  # `font-style`, `text-decoration(-line)`, `text-align` and `white-space:
  # pre*`; the `align` attribute works too. Unknown elements are transparent
  # (children walked); `script`/`style`/`head` subtrees are skipped.
  #
  # Whitespace collapses HTML-style (runs → one space, block-edge trimmed)
  # except under `pre` or a `white-space: pre*` block — which the exporter
  # emits whenever a block's text carries significant spaces, so structural
  # prefixes (list indents) round-trip.
  #
  # The block model matches `TextMarkdown`'s — `ul`/`ol` → one `TextList` per
  # list element, `blockquote` nesting → `TextBlockFormat#quote_level`, `hr` → a
  # `horizontal_rule` block, `pre` → `code_language` rows (one per line), an
  # `img` inline → the picture glyph and alt text, a `p` that is one `img` →
  # a block image (`TextBlockFormat#image`, written back as `<img>`) — so
  # documents cross-convert consistently.
  # `<p>a</p><p>b</p>` imports as two *adjacent* blocks; block spacing is
  # `TextBlockFormat` margins (the margins re-base), carried as
  # `margin-top`/`margin-bottom` styles on export and parsed back on import
  # (1em/1lh = one blank row). An empty, unstyled, top-level `<p></p>` —
  # hand-written HTML's blank separator — also imports as a top margin on
  # whatever follows rather than as an empty block.
  # `dim`/`inverse`/`blink` have no HTML form and are dropped on export.
  module TextHtml
    WS_RUN = /[ \t\r\n\f]+/

    # Parses an HTML document or fragment into detached blocks.
    def self.parse(html : String) : Array(TextBlock)
      Importer.new.import(html)
    end

    # Serializes *blocks* to HTML (a body fragment, one element per block,
    # plus the structural wrappers): consecutive same-instance list members
    # group under one `<ul>`/`<ol>`, an item's `<li>` holding what belongs to
    # it — a nested list, a continuation paragraph or code block at its
    # content column — as HTML nests them (the shape the importer reads back);
    # quote levels nest `<blockquote>`s, rule blocks emit `<hr>`. An empty
    # document — one empty, unformatted block — is no HTML at all, as a
    # Markdown renderer gives for an empty file and the importer reads back.
    def self.generate(blocks : Array(TextBlock)) : String
      return "" if blocks.size == 1 && (only = blocks[0]).fragments.empty? &&
                   only.block_format == TextBlockFormat.default
      String.build do |io|
        qdepth = 0
        open_lists = [] of TextListFormat
        # Per open list level, whether its last item's `<li>` is still open:
        # an item ends where the next one at its level, or anything outside
        # it, starts.
        open_items = [] of Bool
        # Items emitted so far per list instance — numbers a group reopened
        # after an interruption via `<ol start=…>`.
        list_items = {} of UInt64 => Int32
        emitted_tables = Set(UInt64).new
        # The last block of the code run already written whole (`write_pre`).
        run_end = -1
        blocks.each_with_index do |b, i|
          next if i <= run_end
          bf = b.block_format
          # Quote wrappers first; a level change closes any open lists
          # (lists don't span quote boundaries).
          if bf.quote_level != qdepth
            close_lists(io, open_lists, open_items)
            while qdepth < bf.quote_level
              io << "<blockquote>"
              qdepth += 1
            end
            while qdepth > bf.quote_level
              io << "</blockquote>"
              qdepth -= 1
            end
          end
          in_item = false
          if lf = bf.list_format
            open_item_list(io, lf, open_lists, open_items, list_items)
          elsif depth = item_depth(bf, open_items)
            # Content of the open item at *depth* (its continuation): inside
            # its `<li>`, after closing the lists nested deeper.
            close_lists(io, open_lists, open_items, depth)
            in_item = true
          else
            close_lists(io, open_lists, open_items)
          end
          if tf = bf.table_format
            # One `<table>` per instance, emitted at its first block; the
            # remaining pre-rendered rows are consumed by it.
            if emitted_tables.add?(tf.object_id)
              io << '\n' if i > 0
              write_table(io, blocks, i, tf)
            end
            next
          end
          # No line break inside an item's `<li>`: it would be the item's
          # text there (a space, or a significant one under pre-wrap).
          io << '\n' if i > 0 && !in_item
          if lf.nil? && bf.code_block? && bf.heading_level == 0
            run_end = code_run_end(blocks, i)
            write_pre(io, blocks, i, run_end, in_item)
          else
            run_end = line_run_end(blocks, i)
            write_block_element(io, blocks, i, run_end, list_items, in_item)
          end
          open_items[-1] = true if lf
        end
        close_lists(io, open_lists, open_items)
        while qdepth > 0
          io << "</blockquote>"
          qdepth -= 1
        end
      end
    end

    # Opens the list of item *lf* down to its nesting level, closing the
    # lists deeper than it, a different list at its depth, and the previous
    # item of its own.
    private def self.open_item_list(io : IO, lf : TextListFormat, open_lists : Array(TextListFormat), open_items : Array(Bool), list_items : Hash(UInt64, Int32)) : Nil
      while (top = open_lists.last?) && (open_lists.size > lf.indent || (open_lists.size == lf.indent && !top.same?(lf)))
        close_lists(io, open_lists, open_items, open_lists.size - 1)
      end
      if open_lists.size == lf.indent && open_items.last?
        io << "</li>"
        open_items[-1] = false
      end
      while open_lists.size < lf.indent
        # A nested list goes inside an item of the level above: the open
        # one, or a bare `<li>` where that level has none (an item that
        # opens with a nested list, `- - a`).
        if open_items.last? == false
          io << "<li>"
          open_items[-1] = true
        end
        open_lists << lf
        open_items << false
        if lf.style.numbered?
          n = lf.start + (list_items[lf.object_id]? || 0)
          io << (n != 1 ? %(<ol start="#{n}">) : "<ol>")
        else
          io << "<ul>"
        end
      end
    end

    # Closes the open lists (and their open items) deeper than *depth*.
    private def self.close_lists(io : IO, open_lists : Array(TextListFormat), open_items : Array(Bool), depth : Int32 = 0) : Nil
      while open_lists.size > depth
        io << "</li>" if open_items.pop
        io << (open_lists.pop.style.numbered? ? "</ol>" : "</ul>")
      end
    end

    # The list level whose open item *bf*'s block continues — a paragraph or
    # code block indented to that item's content column (the importer's
    # `2 × level`), not a table — or nil for a block outside every item.
    private def self.item_depth(bf : TextBlockFormat, open_items : Array(Bool)) : Int32?
      return if bf.list_format || bf.table_format
      ind = bf.indent
      return unless ind > 0 && ind.even?
      depth = ind // 2
      depth if open_items[depth - 1]?
    end

    # The consecutive pre-rendered run of *tf*'s blocks starting at *i*, as
    # `<table>` markup (header row as `<th>`; cell text plain, escaped).
    private def self.write_table(io : IO, blocks : Array(TextBlock), i : Int32, tf : TextTableFormat) : Nil
      data = [] of TextBlock
      j = i
      while j < blocks.size && blocks[j].block_format.table_format.same?(tf)
        data << blocks[j] if TextTable.data_row?(blocks[j].text)
        j += 1
      end
      return if data.empty?
      als = tf.alignments
      io << "<table>"
      data.each_with_index do |b, ri|
        tag = ri == 0 ? "th" : "td"
        io << "<tr>"
        TextTable.row_cells(b).each_with_index do |cell, ci|
          io << '<' << tag
          # Column alignment rides on each cell, the shape both the importer and
          # browsers read back.
          if name = TextAlign.align_name(als.try(&.[ci]?))
            io << %( style="text-align:) << name << '"'
          end
          io << '>' << escape_html(cell) << "</" << tag << '>'
        end
        io << "</tr>"
      end
      io << "</table>"
    end

    # The index of the last line of the fenced code block whose line *i* is:
    # the lines after it that go on with no margin between, in the same
    # quote, language and block style — where a margin, a different fence or
    # anything else ends the block.
    private def self.code_run_end(blocks : Array(TextBlock), i : Int32) : Int32
      first = blocks[i].block_format
      j = i
      while (n = blocks[j + 1]?) && blocks[j].block_format.bottom_margin == 0
        nf = n.block_format
        break unless nf.code_block? && nf.list_format.nil? && nf.table_format.nil? && nf.heading_level == 0
        break unless nf.top_margin == 0 && nf.quote_level == first.quote_level &&
                     nf.code_language == first.code_language && nf.alignment == first.alignment &&
                     nf.bg == first.bg && nf.indent == first.indent
        j += 1
      end
      j
    end

    # The index of the last line of the paragraph whose line *i* is: the
    # lines after it that a hard break started (`  ` or `\` at a line's end
    # in Markdown, `<br>` in HTML), which the model keeps as blocks of their
    # own — no margin between, the same kind of text block in the same quote
    # and alignment, or a list item's continuation at its content column.
    # Written as one element, a `<br>` between lines (Qt's `toHtml` writes
    # its line separator so), they read as one paragraph, as on screen,
    # rather than as paragraphs a margin apart.
    private def self.line_run_end(blocks : Array(TextBlock), i : Int32) : Int32
      head = blocks[i].block_format
      return i unless text_line?(head)
      j = i
      while (n = blocks[j + 1]?) && line_continues?(head, blocks[j].block_format, n.block_format)
        j += 1
      end
      j
    end

    # Whether *cf*'s block goes on the line after *pf*'s in the element that
    # *head*'s block opens: what the importer makes of a `<br>` there.
    private def self.line_continues?(head : TextBlockFormat, pf : TextBlockFormat, cf : TextBlockFormat) : Bool
      return false unless pf.bottom_margin == 0 && cf.top_margin == 0 && text_line?(cf) && cf.list_format.nil?
      return false unless cf.quote_level == head.quote_level && cf.alert_kind == head.alert_kind &&
                          cf.alignment == head.alignment && cf.bg == head.bg
      if lf = head.list_format
        head.heading_level == 0 && cf.heading_level == 0 && cf.indent == lf.indent * 2
      else
        cf.heading_level == head.heading_level && cf.indent == head.indent
      end
    end

    # Whether a block of *bf* is a line of text: not a rule, a code line, a
    # table row or an image.
    private def self.text_line?(bf : TextBlockFormat) : Bool
      !bf.horizontal_rule? && !bf.code_block? && bf.table_format.nil? && bf.image.nil?
    end

    # Lines *first* to *last* of a fenced code block as one `<pre>`, a line
    # break between lines — the element a browser shows as one block and the
    # importer splits back into its lines — rather than a `<pre>` per line,
    # which a browser sets apart by its default margins. The block's margins
    # are its first line's top and its last line's bottom; *in_item*, it
    # sits in a list item's `<li>`, which indents it.
    private def self.write_pre(io : IO, blocks : Array(TextBlock), first : Int32, last : Int32, in_item : Bool = false) : Nil
      head = blocks[first]
      style = block_style(head.block_format, head, in_item)
      if (m = blocks[last].block_format.bottom_margin) > 0 && last != first
        style = style.empty? ? "margin-bottom:#{m}em" : "#{style};margin-bottom:#{m}em"
      end
      io << "<pre"
      io << " style=\"" << style << '"' unless style.empty?
      write_language_class(io, head.block_format)
      io << '>'
      (first..last).each do |k|
        io << '\n' if k > first
        blocks[k].fragments.each { |f| write_fragment(io, f) }
      end
      io << "</pre>"
    end

    # Blocks *first* to *last*, the lines of one paragraph (`line_run_end`),
    # as their element, a `<br>` between lines: `<p>`, `<h*>`, `<pre>`,
    # `<hr>`, a bare `<br>` for a lone empty line — or, for a list item, its
    # `<li>` left open, `generate` closing it once the item's content ends.
    # *in_item*, the block is a list item's continuation, inside its `<li>`,
    # which indents it.
    private def self.write_block_element(io : IO, blocks : Array(TextBlock), first : Int32, last : Int32, list_items : Hash(UInt64, Int32), in_item : Bool = false) : Nil
      b = blocks[first]
      bf = b.block_format
      lf = bf.list_format
      if bf.horizontal_rule?
        style = block_style(bf, b, in_item)
        io << "<hr"
        io << " style=\"" << style << '"' unless style.empty?
        io << '>'
        return
      end
      # A fully-default empty block exports as a bare `<br>`: `<p></p>` is
      # exactly the spacing shape the importer folds into the next block's
      # top margin, which would mutate "a\n\nb" into "a\nb" on a round-trip.
      if last == first && lf.nil? && b.fragments.empty? && bf == TextBlockFormat.default
        io << "<br>"
        return
      end
      if lf
        list_items[lf.object_id] = (list_items[lf.object_id]? || 0) + 1
        tag = "li"
      else
        lvl = bf.heading_level
        # A fenced-code line exports as `<pre>` — the importer's code-block
        # element — so the fence survives an HTML round-trip.
        tag = lvl > 0 ? "h#{lvl.clamp(1, 6)}" : (bf.code_block? ? "pre" : "p")
      end
      style = block_style(bf, b, in_item, blocks[last].block_format.bottom_margin,
        (first + 1..last).any? { |k| pre_wrap?(blocks[k].text) })
      io << '<' << tag
      io << " style=\"" << style << '"' unless style.empty?
      write_language_class(io, bf) if tag == "pre"
      io << '>'
      # A task item leads with a disabled `<input>`, the shape GitHub emits
      # and `html_task_list?`/`stash_task_state` read back.
      if lf && bf.task?
        io << (bf.checked? ? %(<input type="checkbox" checked disabled>) : %(<input type="checkbox" disabled>))
      end
      # A heading inside a list item keeps its level by wrapping only the
      # inline content in `<h*>` inside the `<li>`; the importer's heading
      # branch merges list membership back on the way in.
      inner_heading = lf && (hl = bf.heading_level) > 0 ? "h#{hl.clamp(1, 6)}" : nil
      io << '<' << inner_heading << '>' if inner_heading
      # Likewise a fenced-code line that is itself a list item: `<pre>` inside
      # the `<li>`, so the fence and the bullet both survive.
      inner_pre = lf && inner_heading.nil? && bf.code_block?
      if inner_pre
        io << "<pre"
        write_language_class(io, bf)
        io << '>'
      end
      if img = bf.image
        write_image(io, img, b)
      else
        (first..last).each do |k|
          io << "<br>" if k > first
          blocks[k].fragments.each { |f| write_fragment(io, f) }
        end
      end
      io << "</pre>" if inner_pre
      io << "</" << inner_heading << '>' if inner_heading
      io << "</" << tag << '>' unless lf
    end

    # A block image as the `<img>` it was read from (Qt's `toHtml` writes an
    # image format as `<img src>` too) — inside the `<a>` of the link the
    # block's text carries, when it does — rather than the stand-in text, so
    # the picture survives an HTML round-trip (`Importer#sole_image`).
    private def self.write_image(io : IO, img : TextImageFormat, b : TextBlock) : Nil
      href = b.fragments.first?.try(&.format.anchor_href)
      io << "<a href=\"" << escape_attr(href) << "\">" if href
      io << "<img src=\"" << escape_attr(img.name) << "\" alt=\"" << escape_attr(img.alt) << '"'
      if title = img.title
        io << " title=\"" << escape_attr(title) << '"'
      end
      io << '>'
      io << "</a>" if href
    end

    # The ` class="language-<lang>"` attribute carrying a fence's info string
    # (nothing for an unnamed fence).
    private def self.write_language_class(io : IO, bf : TextBlockFormat) : Nil
      lang = bf.code_language
      return if lang.nil? || lang.empty?
      io << " class=\"language-" << escape_attr(lang) << '"'
    end

    # *bf*'s CSS for *b*'s element; *in_item*, without the indent, which the
    # list item's `<li>` holding the element gives it. An element of several
    # lines takes the *bottom* margin of its last, and keeps whitespace when
    # any of them needs it (*pre*).
    private def self.block_style(bf : TextBlockFormat, b : TextBlock, in_item : Bool = false,
                                 bottom : Int32 = bf.bottom_margin, pre : Bool = false) : String
      props = [] of String
      if (a = bf.alignment) && (name = TextAlign.align_name(a))
        props << "text-align:#{name}"
      end
      if (bg = bf.bg) && bg >= 0
        props << "background-color:#{Colors.hex(bg)}"
      end
      # Block spacing as CSS margins (1em = one blank row), so it survives
      # the round-trip into the importer's `margin-*` parsing.
      if (m = bf.top_margin) > 0
        props << "margin-top:#{m}em"
      end
      if bottom > 0
        props << "margin-bottom:#{bottom}em"
      end
      # Block indent as `margin-left` in `ch` (1 column each), parsed back
      # by the importer — a list continuation paragraph keeps its column.
      if (ind = bf.indent) > 0 && !in_item
        props << "margin-left:#{ind}ch"
      end
      # Significant whitespace (list indents, aligned columns, TABs) must
      # survive the reader's HTML collapsing.
      props << "white-space:pre-wrap" if pre || pre_wrap?(b.text)
      props.join(';')
    end

    # Whether *text* has whitespace the importer's HTML collapsing would
    # lose: a leading, trailing or doubled space, or a TAB.
    private def self.pre_wrap?(text : String) : Bool
      text.matches?(/\A |  | \z|\t/)
    end

    private def self.write_fragment(io : IO, f : TextFragment) : Nil
      fmt = f.format
      fg = fmt.fg
      bg = fmt.bg
      has_color = (fg && fg >= 0) || (bg && bg >= 0)
      anchor = fmt.anchor_href
      # Unstyled fast path (the common fragment): just its escaped text — no
      # opener/closer tags, no `closers` array, no color-span `String.build`.
      unless anchor || has_color ||
             fmt.bold? || fmt.italic? || fmt.underline? || fmt.strike? || fmt.code?
        io << escape_html(f.text)
        return
      end
      # Openers, outermost first; matching closers are known literals emitted
      # in reverse below (no array needed).
      if a = anchor
        io << "<a href=\"" << escape_attr(a) << "\">"
      end
      {% for a, tag in {bold: "b", italic: "i", underline: "u", strike: "s", code: "code"} %}
        io << "<{{ tag.id }}>" if fmt.{{ a.id }}?
      {% end %}
      # Color <span> is emitted innermost (after the flag tags), so on
      # re-import its explicit fg/bg patch folds after the flag elements'
      # patches.
      if has_color
        io << "<span style=\""
        wrote = false
        if fg && fg >= 0
          io << "color:" << Colors.hex(fg)
          wrote = true
        end
        if bg && bg >= 0
          io << ';' if wrote
          io << "background-color:" << Colors.hex(bg)
        end
        io << "\">"
      end
      io << escape_html(f.text)
      # Closers, innermost first (reverse of the opener order above).
      io << "</span>" if has_color
      {% for a, tag in {code: "code", strike: "s", underline: "u", italic: "i", bold: "b"} %}
        io << "</{{ tag.id }}>" if fmt.{{ a.id }}?
      {% end %}
      io << "</a>" if anchor
    end

    # Escapes *text* for HTML text content, or — with *quotes* — for a
    # double-quoted attribute value, which additionally needs `"`.
    #
    # Single pass instead of chained `gsub`s (each a full scan + intermediate
    # String); returns `text` unchanged (no allocation) when there's nothing to
    # escape — the common case, decided by one scan rather than one per
    # character of interest. Per-char mapping never re-scans an emitted
    # entity, so nothing is double-escaped.
    private def self.escape_html(text : String, quotes : Bool = false) : String
      return text unless text.each_char.any? { |c| c == '&' || c == '<' || c == '>' || (quotes && c == '"') }
      String.build(text.bytesize + 16) do |io|
        text.each_char do |c|
          case c
          when '&' then io << "&amp;"
          when '<' then io << "&lt;"
          when '>' then io << "&gt;"
          when '"' then quotes ? (io << "&quot;") : (io << c)
          else          io << c
          end
        end
      end
    end

    # :ditto:
    #
    # A named method so the attribute-writing call sites read as intent.
    private def self.escape_attr(text : String) : String
      escape_html text, quotes: true
    end

    # DOM → blocks: a patch stack for inline formats,
    # `TextList`/quote-level/rule block structures, code-bg code blocks.
    private class Importer
      # The block-assembly / inline-patch core: `@blocks`/`@frags`/
      # `@block_format`, the patch stack (`@patches`/`@fmt`), `@quote_depth`,
      # `@list_stack`, `@pending_item`/`@pending_checked`, and the shared
      # `with_patch`/`current_format`/`start_block`/`commit_block`/
      # `adopt_table_blocks`/`finalize_blocks` methods. The html-specific hooks
      # (`take_margin`, `adopt_pending_item`, `pending_item_collapse`,
      # `after_start_block`) are defined below; `format_extra_merge` falls back
      # to the module default (html has no inline strike toggle).
      include TextImport::Builder

      # Whether a block is currently open (html opens blocks eagerly and can
      # discard virgin ones; markdown has no such lifecycle).
      @block_open = false
      # Whether the open block collapses whitespace (false under
      # `white-space: pre*`).
      @collapse = true
      # Block format parsed off the `li` element itself (margins/alignment),
      # consumed together with `@pending_item`.
      @pending_item_format : TextBlockFormat?
      # Whitespace-collapse flag parsed off the `li` element (e.g. a
      # `white-space:pre-wrap` on the item), adopted by the item's first
      # block so TABs / significant spaces survive the round-trip.
      @pending_item_collapse : Bool?
      # Blank rows owed to the next block's `top_margin` (accumulated from
      # empty spacing `<p></p>`s — the margins re-base). An accumulating
      # `Int32` (markdown's owed margin is instead a flat `Bool`), so the
      # margin-adoption step is a per-importer hook.
      @pending_margin = 0
      # Whether the open block was eagerly opened by a wrapper (`<p>`/`<div>`)
      # and hasn't received text yet. A nested block element's leading
      # `end_block(discard_virgin: true)` drops such a block instead of
      # emitting a phantom empty one (`<div><p>x</p></div>` is one block).
      # Explicit empties stay real: `<br>`'s new block is marked non-virgin,
      # and trailing `end_block`s emit unconditionally.
      @block_virgin = false

      # Node traversal / attribute access (`each_child`, `find_element`,
      # `attr_val`, ...) shared with the layout-DOM loader.
      include ::Crysterm::HtmlNodeUtil

      def import(html : String) : Array(TextBlock)
        doc = HTML5.parse(html)
        if body = find_element(doc, "body")
          walk_children(body)
        end
        end_block
        finalize_blocks
      end

      private def walk_children(node : HTML5::Node) : Nil
        each_child(node) { |child| walk child }
      end

      private def walk(node : HTML5::Node) : Nil
        case node.type
        when .text?
          append_text node.data
          return
        when .element?
          # fall through
        else
          return # comments, doctypes
        end

        return if walk_inline_element(node)

        case node.data
        when "p", "div"
          bf, collapse = block_format_from(node)
          end_block(discard_virgin: true)
          # An empty, unstyled, top-level paragraph is spacing, not content
          # (hand-written HTML's separator): it becomes a top margin on
          # whatever block follows. Styled or nested empty paragraphs stay
          # real blocks (a quoted blank line renders its quote bar).
          if @quote_depth == 0 && @list_stack.empty? &&
             bf == TextBlockFormat.default && spacing_only?(node)
            @pending_margin += 1
            return
          end
          # A paragraph that is one image is a block image (the Markdown
          # importer's reading): the block records it, the text is the
          # stand-in the `<img>` branch appends.
          if img = sole_image(node)
            bf = bf.merge(TextBlockFormat.new(image: img))
          end
          start_block(bf, collapse)
          walk_children(node)
          end_block
        when "h1", "h2", "h3", "h4", "h5", "h6"
          lvl = node.data[1].to_i
          bf, collapse = block_format_from(node, heading: lvl)
          end_block(discard_virgin: true)
          start_block(bf, collapse)
          walk_children(node)
          end_block
        when "br"
          # A hard break splits one paragraph into interior lines. The
          # continuation is an interior line (never owed rows above), so it must
          # not inherit the paragraph's top_margin, and the bottom_margin must
          # move to (not be duplicated onto) the continuation so it lands only on
          # the paragraph's last line. Derive the continuation before mutating
          # @block_format, then strip bottom off the block being closed.
          cont = @block_format.with_list_format(nil).with_checked(nil).with_task(nil).with_top_margin(nil)
          collapse = @collapse
          @block_format = @block_format.with_bottom_margin(nil)
          end_block
          start_block(cont, collapse)
          # The break's new block is a real (possibly empty) line — a
          # following block element must not discard it as a wrapper block.
          @block_virgin = false
        when "hr"
          end_block(discard_virgin: true)
          bf, _ = block_format_from(node)
          start_block bf.merge(TextBlockFormat.new(horizontal_rule: true))
          end_block
        when "pre"
          end_block(discard_virgin: true)
          # The block's own style (indent, margins) is kept, so a fence that
          # was list continuation content stays at its column; the fence info
          # string rides on a `language-<lang>` class, on the `<pre>` itself
          # or on its `<code>` child (the GitHub/highlight.js convention).
          bf, _ = block_format_from(node)
          bf = bf.merge(TextBlockFormat.new(code_language: code_language_of(node)))
          fmt = TextCharFormat.new(code: true)
          lines = plain_text_of(node).lchop('\n').chomp.split('\n')
          # The element's margins are the block's: above its first line and
          # below its last, none between its lines.
          last = lines.size - 1
          lines.each_with_index do |line, k|
            lbf = bf
            lbf = lbf.with_top_margin(nil) if k > 0
            lbf = lbf.with_bottom_margin(nil) if k < last
            start_block(lbf, collapse: false)
            @frags << TextFragment.new(line, fmt) unless line.empty?
            end_block
          end
        when "blockquote"
          end_block(discard_virgin: true)
          @quote_depth += 1
          walk_children(node)
          @quote_depth -= 1
          end_block
        when "ul", "ol"
          end_block(discard_virgin: true)
          # `to_i?` accepts values up to `Int32::MAX`, which overflow the
          # plain-Int32 marker/numbering arithmetic downstream; route through
          # `TextListFormat.sanitize_start`, the shared clamp used by every
          # importer, so the model stays sane.
          start = TextListFormat.sanitize_start(attr_val(node, "start").try(&.to_i?) || 1)
          @list_stack << TextListFormat.new(
            style: list_style(node),
            indent: @list_stack.size + 1,
            start: start)
          walk_children(node)
          @list_stack.pop?
        when "li"
          end_block(discard_virgin: true)
          # Consumed by the first block opened inside the item — directly by
          # its text, or by a wrapping `<p>` (loose lists) — so no eager
          # `start_block` here: it would emit an empty member block.
          @pending_item = @list_stack.last?
          # A task item (`<input type=checkbox>`) stashes its state for
          # `start_block`; the input element itself is dropped (void, no
          # text).
          stash_task_state(node)
          # The li's own styles (margins, alignment) ride along, as does its
          # whitespace-collapse flag (a pre-wrap li opens its block uncollapsed).
          ibf, icollapse = block_format_from(node)
          # An item that is one image is a block image, as a `<p>` is.
          if img = sole_image(node)
            ibf = ibf.merge(TextBlockFormat.new(image: img))
          end
          @pending_item_format = ibf == TextBlockFormat.default ? nil : ibf
          @pending_item_collapse = icollapse
          walk_children(node)
          # An empty item opened no block; still emit its (empty) member
          # block, so the exporter's own empty (checkbox) items round-trip.
          start_block if @pending_item && !@block_open
          end_block
          @pending_item = nil
          @pending_item_format = nil
          @pending_item_collapse = nil
          @pending_checked = false
          @pending_task = nil
        when "table"
          end_block(discard_virgin: true)
          # A table that is a list item's first content: materialize the
          # item's (empty) member block *before* the table, so the item keeps
          # its membership and ordered numbering — `import_table` stamps no
          # list format, and the li's deferred `start_block` would otherwise
          # fabricate the member block after the table, out of order.
          if @pending_item
            start_block
            end_block
          end
          import_table(node)
        when "script", "style", "head", "template", "title"
          # skipped subtrees
        else
          walk_children(node)
        end
      end

      # Inline formatting elements — character-format patches around the
      # subtree; returns false for anything else so `walk` handles the
      # block-level cases.
      private def walk_inline_element(node : HTML5::Node) : Bool
        case node.data
        when "b", "strong"
          with_patch(TextCharFormat.new(bold: true)) { walk_children(node) }
        when "i", "em"
          with_patch(TextCharFormat.new(italic: true)) { walk_children(node) }
        when "u", "ins"
          with_patch(TextCharFormat.new(underline: true)) { walk_children(node) }
        when "s", "strike", "del"
          with_patch(TextCharFormat.new(strike: true)) { walk_children(node) }
        when "code", "tt", "kbd", "samp"
          with_patch(TextCharFormat.new(code: true)) { walk_children(node) }
        when "a"
          url = attr_val(node, "href")
          with_patch(TextCharFormat.new(anchor_href: url)) { walk_children(node) }
        when "img"
          # No pictures inline on a cell grid: the Markdown importer's
          # degrade — the `dim` picture-frame glyph, then the alt text.
          alt = attr_val(node, "alt").try(&.strip).presence
          with_patch(TextCharFormat.new(dim: true)) do
            append_text(alt ? "#{image_placeholder} #{alt}" : image_placeholder)
          end
        when "span"
          if patch = style_patch(attr_val(node, "style"))
            with_patch(patch) { walk_children(node) }
          else
            walk_children(node)
          end
        when "font"
          fg = attr_val(node, "color").try { |v| css_color(v) }
          if fg
            with_patch(TextCharFormat.new(fg: fg)) { walk_children(node) }
          else
            walk_children(node)
          end
        else
          return false
        end
        true
      end

      # `<table>` → pre-rendered `TextTable` blocks. The first `<th>` row (or
      # the first row) is the header; cell markup degrades to its plain,
      # whitespace-collapsed text.
      private def import_table(node : HTML5::Node) : Nil
        header = nil
        body = [] of Array(String)
        # Per-column alignment from cell `text-align` styles / `align`
        # attributes (first cell that declares one wins for its column).
        aligns = [] of Tput::AlignFlag?
        trs = [] of HTML5::Node
        collect_trs(node, trs)
        trs.each do |tr|
          cells = [] of String
          has_th = false
          each_element_child(tr) do |child|
            next unless child.data == "td" || child.data == "th"
            has_th = true if child.data == "th"
            if a = cell_align(child)
              while aligns.size <= cells.size
                aligns << nil
              end
              aligns[cells.size] ||= a
            end
            cells << plain_text_of(child).gsub(TextHtml::WS_RUN, " ").strip
          end
          unless cells.empty?
            if header.nil? && has_th
              header = cells
            else
              body << cells
            end
          end
        end
        header ||= body.shift?
        return unless header
        alignments = aligns.any? ? aligns.map { |a| a || Tput::AlignFlag::Left } : nil
        bs = TextTable.build(header, body, alignments)
        adopt_table_blocks(bs)
      end

      # The marker style for a `<ul>`/`<ol>`: decimal for ordered, checkbox
      # for a task list (`html_task_list?`), disc otherwise.
      private def list_style(node : HTML5::Node) : TextListFormat::Style
        if node.data == "ol"
          TextListFormat::Style::Decimal
        elsif html_task_list?(node)
          TextListFormat::Style::Checkbox
        else
          TextListFormat::Style::Disc
        end
      end

      # Stashes the pending `<li>`'s task state for `start_block`: a checkbox
      # `<input>` makes it a task item, checked as the input is — of an `<ol>`
      # too, as GFM boxes `1. [ ] a` — and an item without one in a checkbox
      # list a plain one.
      private def stash_task_state(li : HTML5::Node) : Nil
        lf = @list_stack.last? || return
        if inp = checkbox_input(li)
          @pending_checked = !attr_val(inp, "checked").nil?
          @pending_task = true unless lf.style.checkbox?
        elsif lf.style.checkbox?
          @pending_task = false
        end
      end

      # Whether *list* (`<ul>`) is a GFM task list: some `<li>` holds an
      # `<input type="checkbox">` (as `to_html` and GitHub emit).
      private def html_task_list?(node : HTML5::Node) : Bool
        each_element_child(node) do |li|
          return true if li.data == "li" && checkbox_input(li)
        end
        false
      end

      # The `<input type="checkbox">` directly inside *li*, if any.
      private def checkbox_input(li : HTML5::Node) : HTML5::Node?
        each_element_child(li) do |child|
          if child.data == "input" && attr_val(child, "type").try(&.downcase) == "checkbox"
            return child
          end
        end
        nil
      end

      private def collect_trs(node : HTML5::Node, acc : Array(HTML5::Node)) : Nil
        each_element_child(node) do |child|
          if child.data == "tr"
            acc << child
          elsif child.data == "thead" || child.data == "tbody" || child.data == "tfoot"
            collect_trs(child, acc)
          end
        end
      end

      # === Block assembly ===
      #
      # The `start_block`/`commit_block`/`adopt_table_blocks` skeleton lives in
      # `TextImport::Builder`; the hooks below supply html's divergences from
      # markdown: an accumulating `Int32` owed margin, `<li>` element-style
      # donation, per-item whitespace-collapse adoption, and the collapse /
      # block-open / virgin bookkeeping the shared `start_block` finishes with.

      # Hook (`TextImport::Builder#take_margin`): html's owed margin accumulates
      # in the `Int32` `@pending_margin` and folds additively onto *bf*'s own
      # `top_margin`.
      private def take_margin(bf : TextBlockFormat) : TextBlockFormat
        return bf unless @pending_margin > 0
        bf = bf.merge(TextBlockFormat.new(top_margin: bf.top_margin + @pending_margin))
        @pending_margin = 0
        bf
      end

      # Hook (`TextImport::Builder#adopt_pending_item`): the li element's own
      # block styles apply under the block's (a loose item's `<p>` wins where
      # both specify).
      private def adopt_pending_item(bf : TextBlockFormat) : TextBlockFormat
        if ibf = @pending_item_format
          bf = ibf.merge(bf)
          @pending_item_format = nil
        end
        bf
      end

      # Hook (`TextImport::Builder#pending_item_collapse`): a pre-wrap li opens
      # its first block uncollapsed so its TABs / significant spaces are not run
      # through `WS_RUN`.
      private def pending_item_collapse(collapse : Bool) : Bool
        collapse = false if @pending_item_collapse == false
        @pending_item_collapse = nil
        collapse
      end

      # Hook (`TextImport::Builder#after_start_block`): records the block's
      # collapse mode and marks it open and virgin (a wrapper-opened block a
      # nested block element may later discard).
      private def after_start_block(collapse : Bool) : Nil
        @collapse = collapse
        @block_open = true
        @block_virgin = true
      end

      private def ensure_block : Nil
        start_block unless @block_open
      end

      private def end_block(discard_virgin : Bool = false) : Nil
        return unless @block_open
        if discard_virgin && @block_virgin && @frags.empty?
          # A wrapper's eagerly-opened block that a nested block element
          # replaces: drop it (no phantom empty block), re-donating whatever
          # `start_block` consumed — pending margin and list membership — to
          # the real block that follows.
          @pending_margin += @block_format.top_margin
          if (lf = @block_format.list_format) && @pending_item.nil?
            @pending_item = lf
            @pending_checked = @block_format.checked?
            @pending_task = @block_format.@task
            @pending_item_format ||= @block_format.with_list_format(nil).with_top_margin(nil)
            @pending_item_collapse ||= (@collapse ? nil : false)
          end
          @frags = [] of TextFragment
          @block_format = TextBlockFormat.default
          @block_open = false
          return
        end
        if @collapse && (last = @frags.last?)
          last.text = last.text.rstrip(' ')
          @frags.pop if last.text.empty?
        end
        # The shared emit core (`@blocks << …`, reset `@frags`/`@block_format`);
        # html additionally clears its block-open flag.
        commit_block
        @block_open = false
      end

      private def append_text(str : String) : Nil
        return if str.empty?
        # A pre-wrap list item defers opening its first block until its text
        # arrives; open it now (adopting the li's no-collapse flag) so the
        # text is not run through `WS_RUN` below and its TABs / spaces survive
        # the round-trip.
        ensure_block if !@block_open && @pending_item && @pending_item_collapse == false
        if @block_open && !@collapse
          @frags << TextFragment.new(str.gsub('\n', ' '), current_format)
          @block_virgin = false
          return
        end
        s = str.gsub(TextHtml::WS_RUN, " ")
        if s.starts_with?(' ') && boundary_space?
          s = s.lstrip(' ')
        end
        return if s.empty?
        ensure_block
        @frags << TextFragment.new(s, current_format)
        @block_virgin = false
      end

      # Whether a leading space would be redundant here: block boundary, or
      # the previous run already ends in one.
      private def boundary_space? : Bool
        return true unless @block_open
        last = @frags.last?
        last.nil? || last.text.ends_with?(' ')
      end

      # Whether an element holds nothing but (collapsible) whitespace — the
      # empty `<p></p>` spacing test.
      # The image a `<p>` *is* (`TextBlockFormat#image`): its one child
      # besides whitespace is an `<img>`, or an `<a>` holding exactly one —
      # the shape `TextHtml.generate` writes a block image as, and the
      # Markdown importer's `sole_image` rule.
      private def sole_image(node : HTML5::Node) : TextImageFormat?
        sole = sole_child(node) || return
        sole = sole_child(sole) || return if sole.data == "a"
        return unless sole.data == "img"
        TextImageFormat.new(
          name: attr_val(sole, "src") || "",
          alt: attr_val(sole, "alt").try(&.strip) || "",
          title: attr_val(sole, "title").presence)
      end

      # *node*'s one element child when it has exactly one and no text but
      # whitespace, else `nil`.
      private def sole_child(node : HTML5::Node) : HTML5::Node?
        sole = nil
        each_child(node) do |child|
          case child.type
          when .text?
            return unless child.data.blank?
          when .element?
            return if sole
            sole = child
          end
        end
        sole
      end

      # What stands in for a picture on the cell grid — the glyph the
      # Markdown importer uses, at the same tier (see its `image_placeholder`).
      private def image_placeholder : String
        Glyphs.str(Glyphs::Role::IconImage, Glyphs::Tier::Extended)
      end

      private def spacing_only?(node : HTML5::Node) : Bool
        each_child(node) do |child|
          return false if child.type.element?
          return false if child.type.text? && !child.data.gsub(TextHtml::WS_RUN, "").empty?
        end
        true
      end

      private def plain_text_of(node : HTML5::Node) : String
        String.build { |io| collect_text(node, io) }
      end

      private def collect_text(node : HTML5::Node, io : IO) : Nil
        io << node.data if node.type.text?
        if node.type.element? && node.data == "br"
          io << '\n'
          return
        end
        each_child(node) { |child| collect_text child, io }
      end

      # {block format, collapse?} from a block element's `style`/`align`.
      # The fence info string of a `<pre>`: the `language-<lang>` class on it
      # or on its first `<code>` child; `""` when neither names one.
      private def code_language_of(node : HTML5::Node) : String
        [node, find_element(node, "code")].each do |el|
          next unless el
          attr_val(el, "class").try do |cls|
            cls.split { |c| return c.lchop("language-") if c.starts_with?("language-") }
          end
        end
        ""
      end

      private def block_format_from(node : HTML5::Node, heading : Int32 = 0) : {TextBlockFormat, Bool}
        align = nil
        bg = nil
        mt = mb = ind = nil
        collapse = true
        if st = attr_val(node, "style")
          each_style_decl(st) do |k, v|
            case k
            when "text-align"
              align = align_flag(v.downcase) || align
            when "background-color", "background"
              bg = css_color(v) || bg
            when "margin-top"
              mt = css_rows(v) || mt
            when "margin-bottom"
              mb = css_rows(v) || mb
            when "margin-left"
              ind = css_cols(v) || ind
            when "white-space"
              collapse = !v.downcase.starts_with?("pre")
            end
          end
        end
        if av = attr_val(node, "align")
          align = align_flag(av.downcase) || align
        end
        bf = TextBlockFormat.new(alignment: align, bg: bg,
          top_margin: mt, bottom_margin: mb, indent: ind,
          heading_level: heading > 0 ? heading : nil)
        {bf, collapse}
      end

      # CSS length → blank rows: bare numbers and `em`/`rem`/`lh` count 1:1
      # (the exporter emits `em`), `px` assumes a 16px row. `nil` (ignored)
      # otherwise — incl. `0`, which is "no margin", not a margin of 0 rows.
      private def css_rows(v : String) : Int32?
        if md = v.strip.downcase.match(/\A(\d+(?:\.\d+)?)(em|rem|lh|px)?\z/)
          n = md[1].to_f
          n /= 16 if md[2]? == "px"
          # Clamp before `to_i` — an untrusted `margin-top:99999999999em`
          # must degrade, not raise `OverflowError`.
          rows = n.round.clamp(0.0, 1000.0).to_i
          rows > 0 ? rows : nil
        end
      end

      # CSS length → columns for `margin-left` (block indent): bare numbers
      # and `ch` count 1:1 (the exporter emits `ch`).
      private def css_cols(v : String) : Int32?
        if md = v.strip.downcase.match(/\A(\d+(?:\.\d+)?)(ch)?\z/)
          cols = md[1].to_f.round.clamp(0.0, 1000.0).to_i
          cols > 0 ? cols : nil
        end
      end

      # Column alignment from a table cell's `text-align` style or `align`
      # attribute.
      private def cell_align(cell : HTML5::Node) : Tput::AlignFlag?
        if st = attr_val(cell, "style")
          each_style_decl(st) do |k, v|
            if k == "text-align" && (a = align_flag(v.downcase))
              return a
            end
          end
        end
        attr_val(cell, "align").try { |v| align_flag(v.downcase) }
      end

      private def align_flag(name : String) : Tput::AlignFlag?
        TextAlign.align_flag(name)
      end

      # Yields each `key, value` inline-style declaration of *style*, with the
      # key lower-cased and both sides stripped — the shared `;`-split behind
      # `#block_format_from`, `#style_patch`, and `#cell_align`. Declarations
      # without a `:` (empty/trailing tokens) are skipped; they matched no
      # case in the inline loops anyway.
      private def each_style_decl(style : String, & : String, String ->) : Nil
        style.split(';').each do |decl|
          next unless decl.includes?(':')
          k, _, v = decl.partition(':')
          yield k.strip.downcase, v.strip
        end
      end

      # Inline-format patch from a `style` attribute, or nil when it sets
      # nothing we model.
      private def style_patch(style : String?) : TextCharFormat?
        return unless style
        bold = italic = underline = strike = nil
        fg = bg = nil
        any = false
        each_style_decl(style) do |k, v|
          case k
          when "color"
            if c = css_color(v)
              fg = c
              any = true
            end
          when "background-color", "background"
            if c = css_color(v)
              bg = c
              any = true
            end
          when "font-weight"
            vd = v.downcase
            bold = vd == "bold" || vd == "bolder" || ((n = vd.to_i?) && n >= 600) || false
            any = true
          when "font-style"
            italic = v.downcase.includes?("italic")
            any = true
          when "text-decoration", "text-decoration-line"
            vd = v.downcase
            underline = vd.includes?("underline")
            strike = vd.includes?("line-through")
            any = true
          end
        end
        return unless any
        TextCharFormat.new(bold: bold, italic: italic, underline: underline,
          strike: strike, fg: fg, bg: bg)
      end

      # `nil` for unparseable colors (the `-1` sentinel from
      # `Colors.convert_cached` means "unknown" here, not "default").
      private def css_color(spec : String) : Int32?
        c = Colors.convert_cached(spec)
        c == -1 ? nil : c
      end
    end
  end

  class TextDocument
    # Builds a document from the HTML subset (see `TextHtml`).
    def self.from_html(html : String) : TextDocument
      doc = TextDocument.new
      doc.set_html(html)
      doc
    end

    # Replaces the whole content from HTML (Qt `setHtml`). Same reset
    # semantics as `set_plain_text` (not undoable, cursors rewind). Returns
    # the assigned text.
    def set_html(html : String) : String
      replace_content(TextHtml.parse(html))
      html
    end

    # `=`-setter spelling of `#set_html`.
    def html=(html : String) : String
      set_html(html)
    end

    # The content as HTML (Qt `toHtml`).
    def to_html : String
      TextHtml.generate(blocks_mut)
    end
  end

  class TextDocumentFragment
    # Builds a detached fragment from the HTML subset (see `TextHtml`).
    def self.from_html(html : String) : TextDocumentFragment
      new(TextHtml.parse(html))
    end

    # The fragment as HTML (see `TextHtml`).
    def to_html : String
      TextHtml.generate(@blocks)
    end

    # Alias for `#to_html` — the bare-reader spelling the document also has.
    def html : String
      to_html
    end
  end
end
