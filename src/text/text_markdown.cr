require "markd"

module Crysterm
  # Markdown import/export for `TextDocument` (TEXTEDIT.md Phase 3) — the
  # `QTextDocument::setMarkdown`/`toMarkdown` counterpart. Import walks the
  # `markd` CommonMark AST straight into blocks/fragments (no tag-string
  # intermediate); export walks blocks back to markdown, keying on *semantic*
  # properties (`heading_level`, `TextCharFormat#code?`, `anchor_href`), so
  # the `TextTheme` colors the importer applies never affect round-trips.
  #
  # Mapping (and the Phase-3 approximations, to be re-based when the
  # structures land in Phase 4):
  #
  # - Headings → `TextBlockFormat#heading_level` + theme heading color.
  # - `**`/`*`/`~~`/backticks/links → char formats (`code` spans also get the
  #   theme code colors); images degrade to their alt text.
  # - Paragraph spacing → literal empty separator blocks (block margins do
  #   not render yet); a hard line break starts a new block with no separator.
  # - Lists → literal marker prefixes (`• `, `1. `, `☑ `/`☐ ` for task items)
  #   indented two spaces per nesting level — `TextList` is Phase 4.
  # - Blockquotes → a `│ ` prefix per depth (quote color); thematic breaks →
  #   a rule of `─` glyphs. The exporter recognizes these prefixes/lines.
  # - Fenced code → one block per line, `code`-flagged fragments over a
  #   theme-code-bg block (the exporter's fence detector); the fence info
  #   string is not kept. GFM tables pass through as plain text (Phase 4).
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
      @lists = [] of {ordered: Bool, counter: Int32}
      # List-item marker (text + format) the next `start_block` consumes.
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
          separator if @lists.empty?
          ordered = node.data["type"]? != "bullet"
          start = (node.data["start"]?.try &.as(Int32)) || 1
          @lists << {ordered: ordered, counter: start}
          walk_children(node)
          @lists.pop?
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
          start_block
          @frags << TextFragment.new(TextMarkdown.rule_text, TextCharFormat.new(fg: @theme.rule_color))
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
        @lists.empty? && @quote_depth == 0
      end

      # The empty block that renders paragraph spacing (block margins are a
      # Phase-4 render feature).
      private def separator : Nil
        @blocks << TextBlock.new if @emitted
      end

      private def start_block(bf : TextBlockFormat = TextBlockFormat.default) : Nil
        @frags = [] of TextFragment
        @block_format = bf
        if @quote_depth > 0
          qfmt = TextCharFormat.new(fg: @theme.quote_color)
          @frags << TextFragment.new(TextMarkdown.quote_prefix * @quote_depth, qfmt)
        end
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

      private def set_item_marker(item : Markd::Node) : Nil
        indent = "  " * (@lists.size - 1)
        case task_marker(item)
        when :done
          @pending_marker = {indent + "☑ ", TextCharFormat.new(fg: @theme.quote_color)}
          @strip_task = 4
        when :todo
          @pending_marker = {indent + "☐ ", TextCharFormat.new(fg: @theme.muted_color)}
          @strip_task = 4
        else
          cur = @lists.last?
          if cur && cur[:ordered]
            @pending_marker = {indent + "#{cur[:counter]}. ", TextCharFormat.new(fg: @theme.heading_color)}
            @lists[-1] = {ordered: true, counter: cur[:counter] + 1}
          else
            @pending_marker = {indent + "• ", TextCharFormat.new(fg: @theme.heading_color)}
          end
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
    # levels, `code`-flagged runs over code-bg blocks (fences), the importer's
    # quote/list/rule prefixes, and inline flags/anchors.
    private class Exporter
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
            else
              write_block(io, blocks[i])
              i += 1
            end
          end
        end
      end

      # A fenced-code row: block background set (the importer's code-bg
      # marker) and nothing but `code`-flagged fragments (or blank).
      private def code_line?(b : TextBlock) : Bool
        return false unless b.block_format.bg
        b.fragments.all?(&.format.code?)
      end

      private def write_block(io : IO, b : TextBlock) : Nil
        if (lvl = b.block_format.heading_level) > 0
          io << "#" * lvl << ' '
          write_inline(io, b.fragments)
          return
        end

        text = b.text
        if rule?(text)
          io << "---"
          return
        end

        skip = 0

        # Blockquote depth: repetitions of the importer's `│ ` prefix.
        qp = TextMarkdown.quote_prefix
        depth = 0
        while text[skip, qp.size]? == qp
          skip += qp.size
          depth += 1
        end
        io << "> " * depth

        # List markers (after any quote prefix).
        rest = skip == 0 ? text : text[skip..]
        if md = rest.match(/\A( *)(• |☑ |☐ |\d+\. )/)
          io << md[1]
          case marker = md[2]
          when "• " then io << "- "
          when "☑ " then io << "- [x] "
          when "☐ " then io << "- [ ] "
          else           io << marker
          end
          skip += md[0].size
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
