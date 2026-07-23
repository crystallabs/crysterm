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

    # Parses markdown into detached blocks.
    def self.parse(text : String, theme : TextTheme = TextTheme.default) : Array(TextBlock)
      # `source_pos` records each block's source line/column so the importer
      # can tell a real `[x]` task marker from an escaped `\[x\]` one — markd
      # resolves the escape before the AST, so the text nodes are identical
      # (B17-31).
      doc = Markd::Parser.parse(text, Markd::Options.new(source_pos: true))
      Importer.new(theme, text).import(doc)
    end

    # Serializes *blocks* to markdown.
    def self.generate(blocks : Array(TextBlock)) : String
      Exporter.new.export(blocks)
    end

    # Markd AST → blocks. Inline formatting is a stack of `TextCharFormat`
    # patches (entering `Strong` pushes `bold: true`, …); the current format
    # is the fold of the stack over the default, so nesting works for free.
    private class Importer
      @blocks = [] of TextBlock
      @frags = [] of TextFragment
      @block_format : TextBlockFormat = TextBlockFormat.default
      @patches = [] of TextCharFormat
      @fmt : TextCharFormat?
      @quote_depth = 0
      # Open (nested) lists; one shared `TextListFormat` instance per
      # markdown list — instance identity is list identity.
      @list_stack = [] of TextListFormat
      # List the next `start_block`'s block joins (an item's first block).
      @pending_item : TextListFormat?
      # Whether that pending item is a *checked* checkbox item (its
      # `TextBlockFormat#checked` flag; the list format itself is shared).
      @pending_checked = false
      # Chars of a task-list `[x] ` marker still to strip from upcoming text.
      @strip_task = 0
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
      # reject escaped `\[x\]` markers (B17-31).
      @source : Array(String)

      def initialize(@theme : TextTheme, source : String = "")
        @source = source.split('\n')
      end

      def import(doc : Markd::Node) : Array(TextBlock)
        walk_children(doc)
        @blocks.empty? ? [TextBlock.new] : @blocks
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
          walk_children(node)
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
        txt = node_text(node)
        structure_separator
        # A table-shaped paragraph inside a list item stays ordinary item
        # content: import_table stamps no list membership, so taking the
        # table path there would detach it from the list and shift ordered
        # numbering (the exporter's lead escape keeps the `|` roundtrip
        # stable).
        if TextTable.gfm_table?(txt) && @list_stack.empty?
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
        start = (node.data["start"]?.try &.as(Int32)) || 1
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
      # place (a missed `|| quote_break?` guard was B18-70).
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
          @blocks << TextBlock.new("", block_format: bf)
        end
      end

      # Consumes any owed top-level spacing into *bf*.
      private def take_margin(bf : TextBlockFormat) : TextBlockFormat
        return bf unless @pending_margin
        @pending_margin = false
        bf.merge(TextBlockFormat.new(top_margin: 1))
      end

      private def start_block(bf : TextBlockFormat = TextBlockFormat.default) : Nil
        @frags = [] of TextFragment
        bf = take_margin(bf)
        bf = bf.merge(TextBlockFormat.new(quote_level: @quote_depth)) if @quote_depth > 0
        if li = @pending_item
          # An item's first block is the list item proper.
          bf = bf.merge(TextBlockFormat.new(list_format: li))
          # Checked task item: flag the block (unchecked stays the default).
          bf = bf.merge(TextBlockFormat.new(checked: true)) if @pending_checked
          @pending_item = nil
          @pending_checked = false
        elsif !@list_stack.empty?
          # A continuation block inside an item: indent to roughly the item
          # text column (nesting + a 2-cell marker approximation).
          bf = bf.merge(TextBlockFormat.new(indent: @list_stack.size * 2))
        end
        @block_format = bf
      end

      private def end_block : Nil
        @blocks << TextBlock.new(@frags, @block_format)
        @frags = [] of TextFragment
        @block_format = TextBlockFormat.default
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
        bs[0].block_format = take_margin(bs[0].block_format)
        if @quote_depth > 0
          q = TextBlockFormat.new(quote_level: @quote_depth)
          bs.each { |b| b.block_format = b.block_format.merge(q) }
        end
        @blocks.concat(bs)
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
        s = node_text item
        return if md_escaped_marker?(item)
        if md = s.match(/\A\[([ xX])\]\s/)
          md[1].downcase == "x" ? :done : :todo
        end
      end

      # Whether the item's leading `[` is backslash-escaped in the source.
      # markd resolves `\[` to a plain `[` text node, so the AST alone can't
      # distinguish `\[x\]` (a literal `[x]` in a plain bullet) from a real
      # `[x]` task marker; the item's first block starts at the `\` in the
      # escaped case and at the `[` in the real one (B17-31).
      private def md_escaped_marker?(item : Markd::Node) : Bool
        para = item.first_child?
        return false unless para
        line, col = para.source_pos[0]
        return false unless (l = @source[line - 1]?)
        l[col - 1]? == '\\'
      end

      private def node_text(node : Markd::Node) : String
        String.build { |io| collect_text node, io }
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

      private def with_patch(patch : TextCharFormat, &) : Nil
        @patches << patch
        @fmt = nil
        yield
        @patches.pop
        @fmt = nil
      end

      private def current_format : TextCharFormat
        @fmt ||= begin
          f = @patches.reduce(TextCharFormat.default) { |acc, p| acc.merge(p) }
          @strike ? f.merge(TextCharFormat.new(strike: true)) : f
        end
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
      # interruption, table termination (B17-26/B17-27).
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
        # A plain body paragraph directly after a list item (or a
        # list-continuation paragraph) at the same quote level would be
        # read as a lazy continuation of the item and merge into it on
        # re-import; force a blank line so it stays a standalone
        # paragraph (B17-26).
        return true if cf.indent == 0 && plain_body?(blocks[i]) &&
                       pf.quote_level == cf.quote_level &&
                       (pf.list_format || (pf.indent > 0 && pf.list_format.nil?))
        # An ordered list item whose rendered number is not 1 cannot
        # interrupt a preceding paragraph — without a blank line it
        # lazily merges into that paragraph on re-import. The number is
        # `start + count-so-far`, read before write_block increments the
        # counter, so it equals the number about to render (B17-26).
        if (clf = cf.list_format) && clf.style.numbered? &&
           plain_body?(blocks[i - 1]) &&
           clf.start + (@list_items[clf.object_id]? || 0) != 1
          return true
        end
        # A non-table block — or a second, distinct table — directly
        # after a table run would be swallowed as a data row by the GFM
        # table detector on re-import; force a blank line to end the
        # table (B17-27).
        return true if (ptf = pf.table_format) && !ptf.same?(cf.table_format)
        # An empty list item after a plain paragraph renders as a bare
        # marker ("1. "); with only a newline it lazily merges into the
        # paragraph (an empty item can't interrupt a paragraph even with
        # number 1, so the numbered-!=1 guard above misses it) (B17-45).
        return true if cf.list_format && blocks[i].fragments.empty? &&
                       plain_body?(blocks[i - 1])
        # A table directly after a plain paragraph would be swallowed into
        # that paragraph on re-import (the GFM detector needs the table to
        # begin its own paragraph); force a blank line (B17-45).
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
              write_block(io, blocks[i])
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

      # Does *b*'s text open a CommonMark HTML block of types 1-6 — the
      # kinds that interrupt a paragraph and re-import their lines RAW?
      # Mirrors markd's own start conditions (type 7, a lone complete tag,
      # cannot interrupt a paragraph and is excluded).
      private def html_blockish?(b : TextBlock) : Bool
        t = b.text
        t.starts_with?('<') &&
          Markd::Rule::HTML_BLOCK_OPEN[0, 6].any? { |re| t.matches?(re) }
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

      private def write_block(io : IO, b : TextBlock) : Nil
        bf = b.block_format
        io << "> " * bf.quote_level if bf.quote_level > 0

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
      private def write_inline(io : IO, frags : Array(TextFragment), skip : Int32 = 0, lead : Bool = false) : Nil
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
    def set_markdown(text : String, theme : TextTheme = TextTheme.default) : Nil
      replace_content(TextMarkdown.parse(text, theme))
    end

    # `=`-setter spelling of `#set_markdown` (default theme; use `#set_markdown`
    # for an explicit one).
    def markdown=(text : String) : Nil
      set_markdown(text)
    end

    # The content as markdown (Qt `toMarkdown`).
    def to_markdown : String
      TextMarkdown.generate(blocks)
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
