require "markd"
require "./scrollable_text"

module Crysterm
  class Widget
    # A read-only Markdown viewer, modeled after Qt's `QTextBrowser` fed by
    # `QTextDocument#setMarkdown`. CommonMark is parsed by the `markd` shard and
    # rendered to styled, scrollable terminal text (crysterm style tags), so the
    # output is theme-consistent with the rest of the toolkit rather than raw
    # ANSI. As a `ScrollableText` it scrolls and wraps for free.
    #
    # Supported: headings, **bold**/*italic*, `inline code`, fenced code blocks,
    # blockquotes, ordered/unordered (nestable) lists, thematic breaks, links and
    # images (shown as text). Set the document with `#markdown=` / `#set_markdown`.
    #
    # Links: anchors are collected into `#links` and a link can be activated
    # programmatically with `#activate_link`, which emits `Event::AnchorClick`
    # (the `QTextBrowser::anchorClicked` analog). Link *text* is styled so it
    # reads as a link, but **no terminal hyperlink escape sequences are emitted**
    # and pointer-based clicking is intentionally not wired up yet (that needs its
    # own design pass).
    #
    # ```
    # md = Widget::Markdown.new parent: s, width: 60, height: 20,
    #   style: Style.new(border: true)
    # md.markdown = "# Title\n\nSome **bold** and `code`.\n\n- one\n- two\n"
    # md.on(Event::AnchorClick) { |e| open_browser e.url }
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![Markdown screenshot](../../examples/widget/markdown/markdown-capture.png)
    # <!-- /widget-examples:capture -->
    class Markdown < ScrollableText
      # A link found in the document (Qt's anchor). `text` is the visible label,
      # `url` the destination.
      struct Link
        getter text : String
        getter url : String

        def initialize(@text, @url)
        end
      end

      # The source Markdown.
      getter markdown : String = ""

      # Links discovered in the rendered document, in document order.
      getter links : Array(Link) = [] of Link

      # Element colors (truecolor `0xRRGGBB`); tweak for theming.
      property heading_color : Int32
      property code_color : Int32
      property code_bg : Int32
      property quote_color : Int32
      property link_color : Int32

      def initialize(
        markdown : String = "",
        @heading_color : Int32 = 0x86B5FF,
        @code_color : Int32 = 0xE0A85C,
        @code_bg : Int32 = 0x202833,
        @quote_color : Int32 = 0x86C58A,
        @link_color : Int32 = 0x4FB6E6,
        **box,
      )
        super **box
        self.parse_tags = true
        set_markdown markdown unless markdown.empty?
      end

      # Parses and displays *str* (Qt's `QTextDocument#setMarkdown`).
      def set_markdown(str : String) : Nil
        @markdown = str
        renderer = Renderer.new self
        document = Markd::Parser.parse str
        self.content = renderer.render document
        @links = renderer.links
        request_render
      end

      # :ditto:
      def markdown=(str : String) : String
        set_markdown str
        str
      end

      # Activates the link with the given *url*, emitting `Event::AnchorClick`
      # (Qt's `anchorClicked`). This is the programmatic entry point; pointer
      # click-detection is intentionally not wired up yet.
      def activate_link(url : String) : Nil
        emit Crysterm::Event::AnchorClick, url
      end

      # Walks the `markd` AST and emits crysterm style tags. Mirrors how
      # blessed-contrib pairs `marked` with `marked-terminal`: the parser is the
      # library, the terminal renderer is ours.
      class Renderer < Markd::Renderer
        getter links = [] of Link

        # Active ordered-list counters / bullet flags, innermost last.
        @lists = [] of {ordered: Bool, counter: Int32}
        # While inside a link, its destination + accumulated visible text.
        @link_url : String? = nil
        @link_text = ""
        # Blockquote nesting depth.
        @quote = 0
        # Leading characters still to strip from upcoming text (a task-list item's
        # `[ ] ` / `[x] ` marker, which markd tokenizes as plain text).
        @strip_task = 0
        # While rendering a GFM table (which markd parses as a plain paragraph),
        # the paragraph's text/inline children are suppressed.
        @in_table = false
        # Whether any non-empty output has been emitted (so the first block gets
        # no leading blank line).
        @emitted = false

        def initialize(@md : Markdown)
          super(Markd::Options.new)
        end

        # `Markd::Renderer#render` strips the *first* newline of the output (it
        # trims a leading blank in the HTML case). Prepend a sacrificial one
        # directly to the buffer — not via `#literal`, so it touches neither
        # `@emitted` nor `@last_output` — so our first real line break survives.
        def render(document : Markd::Node) : String
          @output_io << "\n"
          super
        end

        # Track whether anything has been written yet (for `#blank_line`).
        def literal(string : String)
          @emitted = true unless string.empty?
          super
        end

        # --- block elements ----------------------------------------------------

        def heading(node : Markd::Node, entering : Bool)
          if entering
            blank_line
            level = node.data["level"].as(Int32)
            literal "{bold}{#{hex @md.heading_color}-fg}"
            literal("#" * level + " ")
          else
            literal "{/#{hex @md.heading_color}-fg}{/bold}"
            newline
          end
        end

        def paragraph(node : Markd::Node, entering : Bool)
          if entering
            # GFM tables aren't parsed by markd — they arrive as a paragraph of
            # `| … |` rows. Detect and render those as a box-drawing table,
            # suppressing the paragraph's own (text) children.
            txt = node_text node
            if table? txt
              @in_table = true
              render_table txt
              return
            end
            # Separate top-level paragraphs with a blank line; inside a list item
            # a paragraph stays tight (no blank), just a trailing break.
            blank_line if @lists.empty? && @quote == 0
          elsif @in_table
            @in_table = false
          else
            newline unless @quote > 0
          end
        end

        def block_quote(node : Markd::Node, entering : Bool)
          if entering
            blank_line
            @quote += 1
            literal "{#{hex @md.quote_color}-fg}│ "
          else
            @quote -= 1
            literal "{/#{hex @md.quote_color}-fg}"
            newline
          end
        end

        def thematic_break(node : Markd::Node, entering : Bool)
          return unless entering
          blank_line
          literal "{#404a57-fg}" + ("─" * 24) + "{/#404a57-fg}"
          newline
        end

        def code_block(node : Markd::Node, entering : Bool)
          return unless entering
          blank_line
          node.text.chomp.each_line do |line|
            literal "{#{hex @md.code_bg}-bg}{#{hex @md.code_color}-fg}  "
            text_out line
            literal "  {/#{hex @md.code_color}-fg}{/#{hex @md.code_bg}-bg}"
            newline
          end
        end

        def list(node : Markd::Node, entering : Bool)
          if entering
            blank_line if @lists.empty? # space a top-level list from prior block
            ordered = node.data["type"]? != "bullet"
            start = (node.data["start"]?.try &.as(Int32)) || 1
            @lists << {ordered: ordered, counter: start}
          else
            @lists.pop?
            newline
          end
        end

        def item(node : Markd::Node, entering : Bool)
          return unless entering
          return if @lists.empty?
          depth = @lists.size - 1
          literal "  " * depth
          # Task-list item (`- [ ] …` / `- [x] …`): markd renders the marker as
          # plain text, so swap it for a checkbox glyph and strip the `[ ] `.
          case task_marker node
          when :done
            literal "{#{hex @md.quote_color}-fg}☑{/#{hex @md.quote_color}-fg} "
            @strip_task = 4
          when :todo
            literal "{#808a96-fg}☐{/#808a96-fg} "
            @strip_task = 4
          else
            cur = @lists[-1]
            if cur[:ordered]
              literal "{#86B5FF-fg}#{cur[:counter]}.{/#86B5FF-fg} "
              @lists[-1] = {ordered: true, counter: cur[:counter] + 1}
            else
              literal "{#86B5FF-fg}•{/#86B5FF-fg} "
            end
          end
        end

        # --- inline elements ---------------------------------------------------

        def text(node : Markd::Node, entering : Bool)
          return if !entering || @in_table
          text_out node.text
        end

        def strong(node : Markd::Node, entering : Bool)
          return if @in_table
          literal(entering ? "{bold}" : "{/bold}")
        end

        def emphasis(node : Markd::Node, entering : Bool)
          return if @in_table
          literal(entering ? "{italic}" : "{/italic}")
        end

        def code(node : Markd::Node, entering : Bool)
          return if !entering || @in_table
          literal "{#{hex @md.code_bg}-bg}{#{hex @md.code_color}-fg}"
          text_out node.text
          literal "{/#{hex @md.code_color}-fg}{/#{hex @md.code_bg}-bg}"
        end

        def link(node : Markd::Node, entering : Bool)
          return if @in_table
          if entering
            @link_url = node.data["destination"]?.try &.as(String)
            @link_text = ""
            literal "{underline}{#{hex @md.link_color}-fg}"
          else
            literal "{/#{hex @md.link_color}-fg}{/underline}"
            if url = @link_url
              @links << Link.new(@link_text, url)
            end
            @link_url = nil
          end
        end

        def image(node : Markd::Node, entering : Bool)
          # Render the alt text (its child text nodes) prefixed, since we can't
          # show the image inline here.
          literal(entering ? "{#808a96-fg}🖼 " : "{/#808a96-fg}")
        end

        def soft_break(node : Markd::Node, entering : Bool)
          # A soft wrap becomes a space — the widget re-wraps to its width.
          literal " " if entering && !@in_table
        end

        def line_break(node : Markd::Node, entering : Bool)
          newline if entering
        end

        def html_block(node : Markd::Node, entering : Bool)
          return unless entering
          text_out node.text
          newline
        end

        def html_inline(node : Markd::Node, entering : Bool)
          text_out node.text if entering
        end

        # --- helpers -----------------------------------------------------------

        # Emits literal text: drops any pending task-marker prefix, escapes
        # crysterm's `{`/`}` so they aren't read as tags, converts `~~…~~` to a
        # `{strike}` span (markd leaves `~` literal), and captures the link label
        # while inside a link.
        private def text_out(str : String) : Nil
          if @strip_task > 0
            drop = Math.min(@strip_task, str.size)
            @strip_task -= drop
            str = str[drop..]
          end
          @link_text += str unless @link_url.nil?
          # Escape braces first, then wrap `~~…~~` in real `{strike}` tags (added
          # after escaping, so the tags aren't escaped; `Attr::STRIKE` renders it).
          escaped = str.gsub('{', "{open}").gsub('}', "{close}")
          escaped = escaped.gsub(/~~(.+?)~~/) { "{strike}#{$1}{/strike}" }
          literal escaped
        end

        # `:done` / `:todo` if *item* begins with a `[x]`/`[ ]` task marker.
        private def task_marker(item : Markd::Node) : Symbol?
          s = node_text item
          if md = s.match(/\A\[([ xX])\]\s/)
            md[1].downcase == "x" ? :done : :todo
          end
        end

        # Concatenated descendant text of *node* (soft/line breaks → newlines),
        # used for task detection and table parsing.
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

        # Ensures a blank line precedes the next block, except before the very
        # first block (nothing emitted yet).
        private def blank_line : Nil
          return unless @emitted
          newline
          literal "\n"
        end

        private def hex(color : Int32) : String
          "##{color.to_s(16).rjust(6, '0')}"
        end

        # --- GFM tables (rendered as box-drawing text) -------------------------

        # Whether *text* is a GFM table: a header row, then a delimiter row of
        # `-`/`:`/`|`/spaces containing at least one `-`.
        private def table?(text : String) : Bool
          lines = text.lines
          return false if lines.size < 2
          lines[0].includes?('|') &&
            lines[1].matches?(/\A\s*\|?[\s:|-]*-[\s:|-]*\|?\s*\z/) &&
            lines[1].includes?('-')
        end

        # Renders a GFM table to a bordered, column-aligned box-drawing table.
        private def render_table(text : String) : Nil
          rows = text.lines.map(&.strip).reject(&.empty?)
          return if rows.size < 2
          header = split_row rows[0]
          aligns = split_row(rows[1]).map { |c| column_align c }
          body = rows[2..]?.try(&.map { |r| split_row r }) || [] of Array(String)
          cols = header.size
          return if cols == 0

          widths = Array.new(cols, 0)
          ([header] + body).each do |row|
            row.each_with_index { |cell, i| widths[i] = Math.max(widths[i], cell.size) if i < cols }
          end

          blank_line
          table_border widths, '┌', '┬', '┐'
          table_data_row header, widths, aligns, bold: true
          table_border widths, '├', '┼', '┤'
          body.each { |row| table_data_row row, widths, aligns, bold: false }
          table_border widths, '└', '┴', '┘'
        end

        # Splits a `| a | b |` row into trimmed cells (outer pipes optional).
        private def split_row(row : String) : Array(String)
          row.strip.sub(/\A\|/, "").sub(/\|\z/, "").split('|').map(&.strip)
        end

        private def column_align(spec : String) : Symbol
          left = spec.starts_with? ':'
          right = spec.ends_with? ':'
          return :center if left && right
          return :right if right
          :left
        end

        private def table_border(widths : Array(Int32), l : Char, mid : Char, r : Char) : Nil
          literal "{#404a57-fg}"
          literal l.to_s
          widths.each_with_index do |w, i|
            literal "─" * (w + 2)
            literal(i == widths.size - 1 ? r.to_s : mid.to_s)
          end
          literal "{/#404a57-fg}"
          newline
        end

        private def table_data_row(cells : Array(String), widths : Array(Int32),
                                   aligns : Array(Symbol), bold : Bool) : Nil
          literal "{#404a57-fg}│{/#404a57-fg}"
          widths.each_with_index do |w, i|
            cell = cells[i]? || ""
            align = aligns[i]? || :left
            literal " "
            literal "{bold}" if bold
            text_out pad_cell(cell, w, align)
            literal "{/bold}" if bold
            literal " {#404a57-fg}│{/#404a57-fg}"
          end
          newline
        end

        private def pad_cell(cell : String, width : Int32, align : Symbol) : String
          pad = width - cell.size
          return cell if pad <= 0
          case align
          when :right  then (" " * pad) + cell
          when :center then (" " * (pad // 2)) + cell + (" " * (pad - pad // 2))
          else              cell + (" " * pad)
          end
        end
      end
    end
  end
end
