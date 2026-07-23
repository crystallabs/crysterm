require "html5"

module Crysterm
  # HTML-subset import/export for `TextDocument` — the
  # `QTextDocument::setHtml`/`toHtml` counterpart, parsed with the `html5` shard.
  #
  # Supported on import: `p div h1..h6 b/strong i/em u/ins s/strike/del a[href]
  # br hr ul ol li pre code/tt/kbd/samp blockquote span[style] font[color]`,
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
  # `horizontal_rule` block, code blocks as code-bg rows — so documents
  # cross-convert consistently.
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
    def self.parse(html : String, theme : TextTheme = TextTheme.default) : Array(TextBlock)
      Importer.new(theme).import(html)
    end

    # Serializes *blocks* to HTML (a body fragment, one element per block,
    # plus the structural wrappers): consecutive same-instance list members
    # group under one `<ul>`/`<ol>` (nested lists as direct child lists, the
    # form the importer reads back), quote levels nest `<blockquote>`s, rule
    # blocks emit `<hr>`.
    def self.generate(blocks : Array(TextBlock)) : String
      String.build do |io|
        qdepth = 0
        open_lists = [] of TextListFormat
        # Items emitted so far per list instance — numbers a group reopened
        # after an interruption via `<ol start=…>`.
        list_items = {} of UInt64 => Int32
        emitted_tables = Set(UInt64).new
        blocks.each_with_index do |b, i|
          bf = b.block_format
          # Quote wrappers first; a level change closes any open lists
          # (lists don't span quote boundaries).
          if bf.quote_level != qdepth
            close_lists(io, open_lists)
            while qdepth < bf.quote_level
              io << "<blockquote>"
              qdepth += 1
            end
            while qdepth > bf.quote_level
              io << "</blockquote>"
              qdepth -= 1
            end
          end
          if lf = bf.list_format
            # Close lists deeper than this item, or a different list at the
            # same depth; open this one down to its nesting level.
            while (top = open_lists.last?) && (open_lists.size > lf.indent || (open_lists.size == lf.indent && !top.same?(lf)))
              io << (top.style.numbered? ? "</ol>" : "</ul>")
              open_lists.pop
            end
            while open_lists.size < lf.indent
              open_lists << lf
              if lf.style.numbered?
                n = lf.start + (list_items[lf.object_id]? || 0)
                io << (n != 1 ? %(<ol start="#{n}">) : "<ol>")
              else
                io << "<ul>"
              end
            end
          else
            close_lists(io, open_lists)
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
          io << '\n' if i > 0
          write_block_element(io, b, lf, list_items)
        end
        close_lists(io, open_lists)
        while qdepth > 0
          io << "</blockquote>"
          qdepth -= 1
        end
      end
    end

    private def self.close_lists(io : IO, open_lists : Array(TextListFormat)) : Nil
      while top = open_lists.pop?
        io << (top.style.numbered? ? "</ol>" : "</ul>")
      end
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
        TextTable.split_data_row(b.text).each_with_index do |cell, ci|
          io << '<' << tag
          # Column alignment rides on each cell, the shape both the importer and
          # browsers read back.
          if name = align_name(als.try(&.[ci]?))
            io << %( style="text-align:) << name << '"'
          end
          io << '>' << escape_html(cell) << "</" << tag << '>'
        end
        io << "</tr>"
      end
      io << "</table>"
    end

    # Resolves a horizontal-alignment keyword (`"left"`/`"center"`/`"right"`,
    # already case-folded) to a `Tput::AlignFlag` — horizontal center is
    # `HCenter` — or `nil` for an unrecognized name. Callers apply their own
    # default for the `nil` case.
    def self.align_flag(name : String) : Tput::AlignFlag?
      case name
      when "left"   then Tput::AlignFlag::Left
      when "center" then Tput::AlignFlag::HCenter
      when "right"  then Tput::AlignFlag::Right
      end
    end

    # The reverse of `align_flag`: a `Tput::AlignFlag` to its alignment
    # keyword (`"left"`/`"center"`/`"right"`, horizontal center as `"center"`),
    # or `nil` when it carries no horizontal alignment. Shared with `TextTags`,
    # which inverts the same `align_flag` map.
    def self.align_name(a : Tput::AlignFlag?) : String?
      return unless a
      return "center" if a.h_center?
      return "right" if a.right?
      return "left" if a.left?
      nil
    end

    private def self.write_block_element(io : IO, b : TextBlock, lf : TextListFormat?, list_items : Hash(UInt64, Int32)) : Nil
      bf = b.block_format
      if bf.horizontal_rule?
        style = block_style(bf, b)
        io << "<hr"
        io << " style=\"" << style << '"' unless style.empty?
        io << '>'
        return
      end
      # A fully-default empty block exports as a bare `<br>`: `<p></p>` is
      # exactly the spacing shape the importer folds into the next block's
      # top margin, which would mutate "a\n\nb" into "a\nb" on a round-trip.
      if lf.nil? && b.fragments.empty? && bf == TextBlockFormat.default
        io << "<br>"
        return
      end
      if lf
        list_items[lf.object_id] = (list_items[lf.object_id]? || 0) + 1
        tag = "li"
      else
        lvl = bf.heading_level
        tag = lvl > 0 ? "h#{lvl.clamp(1, 6)}" : "p"
      end
      style = block_style(bf, b)
      io << '<' << tag
      io << " style=\"" << style << '"' unless style.empty?
      io << '>'
      # A checkbox item leads with a disabled `<input>`, the shape GitHub
      # emits and `html_task_list?`/`checkbox_checked?` read back.
      if lf && lf.style.checkbox?
        io << (bf.checked? ? %(<input type="checkbox" checked disabled>) : %(<input type="checkbox" disabled>))
      end
      # A heading inside a list item keeps its level by wrapping only the
      # inline content in `<h*>` inside the `<li>`; the importer's heading
      # branch merges list membership back on the way in.
      inner_heading = lf && (hl = bf.heading_level) > 0 ? "h#{hl.clamp(1, 6)}" : nil
      io << '<' << inner_heading << '>' if inner_heading
      b.fragments.each { |f| write_fragment(io, f) }
      io << "</" << inner_heading << '>' if inner_heading
      io << "</" << tag << '>'
    end

    private def self.block_style(bf : TextBlockFormat, b : TextBlock) : String
      props = [] of String
      if (a = bf.alignment) && (name = align_name(a))
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
      if (m = bf.bottom_margin) > 0
        props << "margin-bottom:#{m}em"
      end
      # Block indent as `margin-left` in `ch` (1 column each), parsed back
      # by the importer — a list continuation paragraph keeps its column.
      if (ind = bf.indent) > 0
        props << "margin-left:#{ind}ch"
      end
      # Significant whitespace (list indents, aligned columns, TABs) must
      # survive the reader's HTML collapsing.
      props << "white-space:pre-wrap" if b.text.matches?(/\A |  | \z|\t/)
      props.join(';')
    end

    private def self.write_fragment(io : IO, f : TextFragment) : Nil
      fmt = f.format
      closers = [] of String
      if url = fmt.anchor_href
        io << "<a href=\"" << escape_attr(url) << "\">"
        closers << "</a>"
      end
      {% for a, tag in {bold: "b", italic: "i", underline: "u", strike: "s", code: "code"} %}
        if fmt.{{ a.id }}?
          io << "<{{ tag.id }}>"
          closers << "</{{ tag.id }}>"
        end
      {% end %}
      # Color <span> is emitted innermost (after the flag tags) so that on
      # re-import its explicit fg/bg patch folds after the code element's
      # theme-fallback patch and wins — otherwise a recolored code fragment
      # comes back with the theme's code colors (B17-30).
      span = String.build do |s|
        if (c = fmt.fg) && c >= 0
          s << "color:" << Colors.hex(c)
        end
        if (c = fmt.bg) && c >= 0
          s << ';' unless s.empty?
          s << "background-color:" << Colors.hex(c)
        end
      end
      unless span.empty?
        io << "<span style=\"" << span << "\">"
        closers << "</span>"
      end
      io << escape_html(f.text)
      closers.reverse_each { |t| io << t }
    end

    private def self.escape_html(text : String) : String
      text.gsub('&', "&amp;").gsub('<', "&lt;").gsub('>', "&gt;")
    end

    private def self.escape_attr(text : String) : String
      escape_html(text).gsub('"', "&quot;")
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

      def initialize(@theme : TextTheme)
      end

      def import(html : String) : Array(TextBlock)
        doc = HTML5.parse(html)
        if body = find_body(doc)
          walk_children(body)
        end
        end_block
        finalize_blocks
      end

      private def find_body(node : HTML5::Node) : HTML5::Node?
        return node if node.type.element? && node.data == "body"
        child = node.first_child
        while child
          if found = find_body(child)
            return found
          end
          child = child.next_sibling
        end
        nil
      end

      private def walk_children(node : HTML5::Node) : Nil
        child = node.first_child
        while child
          walk(child)
          child = child.next_sibling
        end
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
          start_block(bf, collapse)
          walk_children(node)
          end_block
        when "h1", "h2", "h3", "h4", "h5", "h6"
          lvl = node.data[1].to_i
          bf, collapse = block_format_from(node, heading: lvl)
          end_block(discard_virgin: true)
          start_block(bf, collapse)
          with_patch(TextCharFormat.new(fg: @theme.heading_color)) { walk_children(node) }
          end_block
        when "br"
          # A hard break splits one paragraph into interior lines. The
          # continuation is an interior line (never owed rows above), so it must
          # not inherit the paragraph's top_margin, and the bottom_margin must
          # move to (not be duplicated onto) the continuation so it lands only on
          # the paragraph's last line. Derive the continuation before mutating
          # @block_format, then strip bottom off the block being closed.
          cont = @block_format.with_list_format(nil).with_checked(nil).with_top_margin(nil)
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
          bf = TextBlockFormat.new(bg: @theme.code_bg)
          fmt = TextCharFormat.new(code: true, fg: @theme.code_color)
          plain_text_of(node).lchop('\n').chomp.split('\n').each do |line|
            start_block(bf, collapse: false)
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
          # A checkbox item (`<input type=checkbox>`) stashes its checked
          # state for `start_block`; the input element itself is dropped
          # (void, no text).
          @pending_checked = pending_item_checked?(node)
          # The li's own styles (margins, alignment) ride along, as does its
          # whitespace-collapse flag (a pre-wrap li opens its block uncollapsed).
          ibf, icollapse = block_format_from(node)
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
          with_patch(TextCharFormat.new(code: true, fg: @theme.code_color, bg: @theme.code_bg)) do
            walk_children(node)
          end
        when "a"
          url = attr_val(node, "href")
          with_patch(TextCharFormat.new(fg: @theme.link_color, anchor_href: url)) { walk_children(node) }
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
          child = tr.first_child
          while child
            if child.type.element? && (child.data == "td" || child.data == "th")
              has_th = true if child.data == "th"
              if a = cell_align(child)
                while aligns.size <= cells.size
                  aligns << nil
                end
                aligns[cells.size] ||= a
              end
              cells << plain_text_of(child).gsub(TextHtml::WS_RUN, " ").strip
            end
            child = child.next_sibling
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
        bs = TextTable.build(header, body, alignments, @theme)
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

      # Whether the pending `<li>` is a *checked* item — only when its list is
      # a checkbox list (a stray `<input>` in a plain list is ignored).
      private def pending_item_checked?(li : HTML5::Node) : Bool
        lf = @list_stack.last?
        return false unless lf && lf.style.checkbox?
        checkbox_checked?(li)
      end

      # Whether *list* (`<ul>`) is a GFM task list: some `<li>` holds an
      # `<input type="checkbox">` (as `to_html` and GitHub emit).
      private def html_task_list?(node : HTML5::Node) : Bool
        li = node.first_child
        while li
          return true if li.type.element? && li.data == "li" && checkbox_input(li)
          li = li.next_sibling
        end
        false
      end

      # The `<input type="checkbox">` directly inside *li*, if any.
      private def checkbox_input(li : HTML5::Node) : HTML5::Node?
        child = li.first_child
        while child
          if child.type.element? && child.data == "input" &&
             attr_val(child, "type").try(&.downcase) == "checkbox"
            return child
          end
          child = child.next_sibling
        end
        nil
      end

      # Whether *li*'s checkbox input carries the boolean `checked` attribute.
      private def checkbox_checked?(li : HTML5::Node) : Bool
        (inp = checkbox_input(li)) ? !attr_val(inp, "checked").nil? : false
      end

      private def collect_trs(node : HTML5::Node, acc : Array(HTML5::Node)) : Nil
        child = node.first_child
        while child
          if child.type.element?
            if child.data == "tr"
              acc << child
            elsif child.data == "thead" || child.data == "tbody" || child.data == "tfoot"
              collect_trs(child, acc)
            end
          end
          child = child.next_sibling
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
        # the round-trip (T3).
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
      private def spacing_only?(node : HTML5::Node) : Bool
        child = node.first_child
        while child
          return false if child.type.element?
          return false if child.type.text? && !child.data.gsub(TextHtml::WS_RUN, "").empty?
          child = child.next_sibling
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
        child = node.first_child
        while child
          collect_text(child, io)
          child = child.next_sibling
        end
      end

      private def attr_val(node : HTML5::Node, key : String) : String?
        node.attr.each do |a|
          return a.val if a.key == key
        end
        nil
      end

      # {block format, collapse?} from a block element's `style`/`align`.
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
        TextHtml.align_flag(name)
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
    def self.from_html(html : String, theme : TextTheme = TextTheme.default) : TextDocument
      doc = TextDocument.new
      doc.set_html(html, theme)
      doc
    end

    # Replaces the whole content from HTML (Qt `setHtml`). Same reset
    # semantics as `set_plain_text` (not undoable, cursors rewind).
    def set_html(html : String, theme : TextTheme = TextTheme.default) : Nil
      replace_content(TextHtml.parse(html, theme))
    end

    # `=`-setter spelling of `#set_html` (default theme; use `#set_html` for an
    # explicit one).
    def html=(html : String) : Nil
      set_html(html)
    end

    # The content as HTML (Qt `toHtml`).
    def to_html : String
      TextHtml.generate(blocks)
    end
  end

  class TextDocumentFragment
    # Builds a detached fragment from the HTML subset (see `TextHtml`).
    def self.from_html(html : String, theme : TextTheme = TextTheme.default) : TextDocumentFragment
      new(TextHtml.parse(html, theme))
    end

    # The fragment as HTML (see `TextHtml`).
    def to_html : String
      TextHtml.generate(@blocks)
    end
  end
end
