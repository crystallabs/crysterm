require "markd"

module Crysterm
  # Markdown import/export for `TextDocument` (TEXTEDIT.md Phase 3) — the
  # `QTextDocument::setMarkdown`/`toMarkdown` counterpart. Import walks the
  # `markd` CommonMark AST straight into blocks/fragments (no tag-string
  # intermediate); export walks blocks back to markdown, keying on *semantic*
  # properties (`heading_level`, `TextCharFormat#code?`, `anchor_href`), so
  # the `TextTheme` colors the importer applies never affect round-trips.
  #
  # Mapping (re-based onto the Phase-4 structures):
  #
  # - Headings → `TextBlockFormat#heading_level` + theme heading color.
  # - `**`/`*`/`~~`/backticks/links → char formats (`code` spans also get the
  #   theme code colors); images degrade to their alt text.
  # - Paragraph spacing → literal empty separator blocks (kept from Phase 3;
  #   HTML cross-conversion relies on it); a hard line break starts a new
  #   block with no separator.
  # - Lists → one `TextList` per markdown list (disc/decimal style, nesting
  #   via `TextListFormat#indent`); the widget renders markers/indent as
  #   decorations. An item's continuation blocks get a plain block indent
  #   approximation. GFM task items stay literal `☑ `/`☐ ` marker prefixes
  #   (no `TextList`) — there is no checkbox marker style.
  # - Blockquotes → `TextBlockFormat#quote_level`; thematic breaks → an
  #   empty `horizontal_rule` block.
  # - Fenced code → one block per line, `code`-flagged fragments over a
  #   theme-code-bg block (the exporter's fence detector); the fence info
  #   string is not kept. GFM tables pass through as plain text (tables are
  #   the Phase-4 tail).
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
      Importer.new(theme).import(Markd::Parser.parse(text))
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
      # Task-item marker (text + format) the next `start_block` consumes —
      # task items stay literal (no checkbox `TextListFormat::Style`).
      @pending_marker : {String, TextCharFormat}?
      # Chars of a task-list `[x] ` marker still to strip from upcoming text.
      @strip_task = 0
      # Whether any block was emitted (suppresses the first separator).
      @emitted = false

      def initialize(@theme : TextTheme)
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
          # markd hands GFM tables through as a plain paragraph of `|` rows —
          # the same detection `Widget::Markdown` uses.
          txt = node_text(node)
          if TextTable.gfm_table?(txt)
            separator if top_level?
            import_table(txt)
            return
          end
          separator if top_level?
          start_block
          walk_children(node)
          end_block
        when .heading?
          separator
          start_block TextBlockFormat.new(heading_level: node.data["level"].as(Int32))
          with_patch(TextCharFormat.new(fg: @theme.heading_color)) { walk_children(node) }
          end_block
        when .block_quote?
          separator if top_level?
          @quote_depth += 1
          walk_children(node)
          @quote_depth -= 1
        when .list?
          separator if @list_stack.empty?
          ordered = node.data["type"]? != "bullet"
          start = (node.data["start"]?.try &.as(Int32)) || 1
          @list_stack << TextListFormat.new(
            style: ordered ? TextListFormat::Style::Decimal : TextListFormat::Style::Disc,
            indent: @list_stack.size + 1,
            start: start)
          walk_children(node)
          @list_stack.pop?
        when .item?
          set_item_marker(node)
          walk_children(node)
        when .code_block?
          separator
          fmt = TextCharFormat.new(code: true, fg: @theme.code_color)
          bf = TextBlockFormat.new(bg: @theme.code_bg)
          node.text.chomp.split('\n').each do |line|
            start_block bf
            @frags << TextFragment.new(line, fmt) unless line.empty?
            end_block
          end
        when .thematic_break?
          separator
          start_block TextBlockFormat.new(horizontal_rule: true)
          end_block
        when .html_block?
          separator if top_level?
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
          # No inline images on a cell grid (Phase 4+): degrade to alt text.
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

      private def top_level? : Bool
        @list_stack.empty? && @quote_depth == 0
      end

      # The empty block that renders paragraph spacing. Kept literal (not
      # block margins) so HTML cross-conversion — where spacing is explicit
      # markup — stays symmetric.
      private def separator : Nil
        if @emitted
          bf = @quote_depth > 0 ? TextBlockFormat.new(quote_level: @quote_depth) : TextBlockFormat.default
          @blocks << TextBlock.new("", block_format: bf)
        end
      end

      private def start_block(bf : TextBlockFormat = TextBlockFormat.default) : Nil
        @frags = [] of TextFragment
        bf = bf.merge(TextBlockFormat.new(quote_level: @quote_depth)) if @quote_depth > 0
        if li = @pending_item
          # An item's first block is the list item proper.
          bf = bf.merge(TextBlockFormat.new(list_format: li))
          @pending_item = nil
        elsif !@list_stack.empty? && @pending_marker.nil?
          # A continuation block inside an item: indent to roughly the item
          # text column (nesting + a 2-cell marker approximation).
          bf = bf.merge(TextBlockFormat.new(indent: @list_stack.size * 2))
        end
        @block_format = bf
        if pm = @pending_marker
          @frags << TextFragment.new(pm[0], pm[1])
          @pending_marker = nil
        end
      end

      private def end_block : Nil
        @blocks << TextBlock.new(@frags, @block_format)
        @frags = [] of TextFragment
        @block_format = TextBlockFormat.default
        @emitted = true
      end

      # Appends a GFM table's pre-rendered blocks (see `TextTable.build`),
      # carrying any enclosing quote level. Cell inline markup degrades to
      # its plain text (markd never parsed it).
      private def import_table(txt : String) : Nil
        bs = TextTable.build_from_gfm(txt, @theme) || return
        if @quote_depth > 0
          q = TextBlockFormat.new(quote_level: @quote_depth)
          bs.each { |b| b.block_format = b.block_format.merge(q) }
        end
        @blocks.concat(bs)
        @emitted = true
      end

      private def set_item_marker(item : Markd::Node) : Nil
        case task_marker(item)
        when :done
          @pending_marker = {"  " * (@list_stack.size - 1) + "☑ ", TextCharFormat.new(fg: @theme.quote_color)}
          @strip_task = 4
        when :todo
          @pending_marker = {"  " * (@list_stack.size - 1) + "☐ ", TextCharFormat.new(fg: @theme.muted_color)}
          @strip_task = 4
        else
          @pending_item = @list_stack.last?
        end
      end

      # `:done` / `:todo` if *item* begins with a `[x]`/`[ ]` task marker
      # (markd tokenizes it as plain text — same detection as
      # `Widget::Markdown`).
      private def task_marker(item : Markd::Node) : Symbol?
        s = node_text item
        if md = s.match(/\A\[([ xX])\]\s/)
          md[1].downcase == "x" ? :done : :todo
        end
      end

      private def node_text(node : Markd::Node) : String
        String.build { |io| collect_text node, io }
      end

      private def collect_text(node : Markd::Node, io : IO) : Nil
        child = node.first_child?
        while child
          case child.type
          when .text?, .code?             then io << child.text
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
        @fmt ||= @patches.reduce(TextCharFormat.default) { |acc, p| acc.merge(p) }
      end

      private def push_frag(text : String) : Nil
        @frags << TextFragment.new(text, current_format) unless text.empty?
      end

      # Emits literal text: drops a pending task-marker prefix and converts
      # `~~…~~` spans to strike runs (markd leaves `~` literal).
      private def append_text(str : String) : Nil
        if @strip_task > 0
          drop = Math.min(@strip_task, str.size)
          @strip_task -= drop
          str = str[drop..]
        end
        return if str.empty?
        pos = 0
        while md = /~~(.+?)~~/.match(str, pos)
          push_frag str[pos...md.begin(0)]
          with_patch(TextCharFormat.new(strike: true)) { push_frag md[1] }
          pos = md.begin(0) + md[0].size
        end
        push_frag str[pos..]
      end
    end

    # Blocks → markdown. Works purely off block/char structure: heading
    # levels, `code`-flagged runs over code-bg blocks (fences), the
    # quote-level/list/rule block properties, the literal task markers, and
    # inline flags/anchors.
    private class Exporter
      # Items emitted so far per list instance (identity-keyed) — the
      # numbering source for ordered markers.
      @list_items = {} of UInt64 => Int32

      def export(blocks : Array(TextBlock)) : String
        String.build do |io|
          i = 0
          while i < blocks.size
            io << '\n' if i > 0
            if code_line?(blocks[i])
              io << "```\n"
              while i < blocks.size && code_line?(blocks[i])
                io << blocks[i].text << '\n'
                i += 1
              end
              io << "```"
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
        rows = data.map { |b| TextTable.split_data_row(b.text) }
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
      # marker) and nothing but `code`-flagged fragments (or blank).
      private def code_line?(b : TextBlock) : Bool
        return false unless b.block_format.bg
        b.fragments.all?(&.format.code?)
      end

      private def write_block(io : IO, b : TextBlock) : Nil
        bf = b.block_format
        io << "> " * bf.quote_level if bf.quote_level > 0

        if bf.horizontal_rule?
          io << "---"
          return
        end

        if lf = bf.list_format
          io << "  " * (lf.indent - 1)
          n = @list_items[lf.object_id]? || 0
          @list_items[lf.object_id] = n + 1
          io << (lf.style.numbered? ? "#{lf.start + n}. " : "- ")
          write_inline(io, b.fragments)
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

        # Literal GFM task markers (task items carry no `TextList`).
        skip = 0
        if md = text.match(/\A( *)(☑ |☐ )/)
          io << md[1] << (md[2] == "☑ " ? "- [x] " : "- [ ] ")
          skip = md[0].size
        end

        write_inline(io, b.fragments, skip)
      end

      # A thematic break: nothing but rule glyphs (or plain dashes, which
      # markdown reads as an HR anyway).
      private def rule?(text : String) : Bool
        return false if text.size < 3
        rule_char = Glyphs[Glyphs::Role::LineHorizontal, Glyphs::Tier::Unicode]
        text.each_char.all? { |c| c == rule_char || c == '-' }
      end

      # Fragments as inline markdown, skipping the first *skip* chars (the
      # structural prefixes handled above).
      private def write_inline(io : IO, frags : Array(TextFragment), skip : Int32 = 0) : Nil
        frags.each do |f|
          t = f.text
          if skip > 0
            d = Math.min(skip, t.size)
            skip -= d
            t = t[d..]
          end
          next if t.empty?
          fmt = f.format
          if fmt.code?
            io << wrap_code(t)
          elsif url = fmt.anchor_href
            io << '['
            write_emphasis(io, t, fmt)
            io << "](" << url << ')'
          else
            write_emphasis(io, t, fmt)
          end
        end
      end

      # Bold/italic/strike markers around escaped text. Underline, colors and
      # the other SGR flags have no markdown form and are dropped.
      private def write_emphasis(io : IO, text : String, fmt : TextCharFormat) : Nil
        em = fmt.bold? ? (fmt.italic? ? "***" : "**") : (fmt.italic? ? "*" : "")
        io << "~~" if fmt.strike?
        io << em << escape_md(text) << em
        io << "~~" if fmt.strike?
      end

      private def wrap_code(text : String) : String
        text.includes?('`') ? "`` #{text} ``" : "`#{text}`"
      end

      private def escape_md(text : String) : String
        return text unless text.matches?(/[\\`*_\[\]]/)
        text.gsub(/([\\`*_\[\]])/) { "\\#{$1}" }
      end
    end
  end

  class TextDocument
    # Builds a document from markdown (see `TextMarkdown`).
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

    # The content as markdown (Qt `toMarkdown`).
    def to_markdown : String
      TextMarkdown.generate(blocks)
    end
  end

  class TextDocumentFragment
    # Builds a detached fragment from markdown (see `TextMarkdown`).
    def self.from_markdown(text : String, theme : TextTheme = TextTheme.default) : TextDocumentFragment
      new(TextMarkdown.parse(text, theme))
    end

    # The fragment as markdown (see `TextMarkdown`).
    def to_markdown : String
      TextMarkdown.generate(@blocks)
    end
  end
end
