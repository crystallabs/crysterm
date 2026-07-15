require "markd"
require "./scrollable_text"

module Crysterm
  class Widget
    # A read-only Markdown viewer, modeled after Qt's `QTextBrowser` fed by
    # `QTextDocument#setMarkdown`. GitHub Flavored Markdown is parsed by the
    # `markd` shard and rendered to styled, scrollable terminal text (crysterm
    # style tags) rather than raw ANSI. As a `ScrollableText` it scrolls and
    # wraps for free.
    #
    # Supported: headings, **bold**/*italic*/~~strikethrough~~, `inline code`,
    # fenced code blocks, blockquotes and alerts (`> [!NOTE]`), ordered/unordered
    # /task (nestable) lists, tables, thematic breaks, links and images (shown as
    # text). Set the document with `#markdown=` / `#set_markdown`.
    #
    # Links: anchors are collected into `#links` and a link can be activated
    # programmatically with `#activate_link`, which emits `Event::AnchorClick`
    # (the `QTextBrowser::anchorClicked` analog). Link *text* is styled so it
    # reads as a link, but **no terminal hyperlink escape sequences are emitted**
    # and pointer-based clicking is not wired up.
    #
    # ```
    # md = Widget::Markdown.new parent: s, width: 60, height: 20,
    #   style: Style.new(border: true)
    # md.markdown = "# Title\n\nSome **bold** and `code`.\n\n- one\n- two\n"
    # md.on(Event::AnchorClick) { |e| open_browser e.url }
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![Markdown screenshot](../../tests/widget/markdown/markdown.5s.apng)
    # <!-- /widget-examples:capture -->
    class Markdown < ScrollableText
      # Parser and renderer options; both must agree, so they share one instance.
      # GFM buys tables, task lists, strikethrough and alerts natively.
      # `Markd::Options` is a mutable class — sharing is safe only because
      # nothing mutates it (the renderer reads `@options` for `Utils.timer`
      # alone), so don't hand it out to callers.
      OPTIONS = Markd::Options.new(gfm: true)

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
        document = Markd::Parser.parse str, OPTIONS
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
      # (Qt's `anchorClicked`). Programmatic entry point; pointer click-detection
      # is not wired up.
      def activate_link(url : String) : Nil
        emit Crysterm::Event::AnchorClick, url
      end

      # Walks the `markd` AST and emits crysterm style tags.
      class Renderer < Markd::Renderer
        getter links = [] of Link

        # Active ordered-list counters / bullet flags, innermost last.
        @lists = [] of {ordered: Bool, counter: Int32}
        # While inside a link, its destination + accumulated visible text.
        @link_url : String? = nil
        @link_text = ""
        # Blockquote/alert nesting depth.
        @quote = 0
        # Whether any non-empty output has been emitted (so the first block gets
        # no leading blank line).
        @emitted = false
        # While inside a table cell, output is diverted here rather than emitted,
        # and the cell's visible width accumulated alongside it. The width is
        # counted as we go because a rendered cell is a mix of visible text and
        # style tags, and afterwards the two can't be told apart: `{open}` and
        # `{close}` are how `#text_out` escapes a literal brace, and they look
        # exactly like tags while occupying one column each.
        @capture : String::Builder? = nil
        @capture_width = 0
        # The table being built: finished rows of `{rendered, visible width}`
        # cells, plus the per-column alignment taken from the header row.
        @rows = [] of {cells: Array({String, Int32}), heading: Bool}
        @row = [] of {String, Int32}
        @aligns = [] of String

        def initialize(@md : Markdown)
          super(OPTIONS)
        end

        # `Markd::Renderer#render` strips the first newline of the output, so
        # prepend a sacrificial one straight to the buffer — not via `#literal`,
        # which would touch `@emitted`/`@last_output`. The *formatter* argument
        # is markd's code-block syntax highlighter; code blocks are styled here,
        # so it stays `nil`.
        def render(document : Markd::Node) : String
          @output_io << "\n"
          super document, nil
        end

        # Diverts into the cell capture, or tracks whether anything has been
        # written yet (for `#blank_line`). A capture deliberately touches neither
        # `@emitted` nor `@last_output`: nothing has been emitted until the
        # finished cell is painted as part of its row.
        def literal(string : String)
          if cap = @capture
            cap << string
            return
          end
          @emitted = true unless string.empty?
          super
        end

        # A cell is a single line by construction (`rules/table.cr` splits rows
        # on newlines), so a newline reaching a capture — from a hard break in
        # cell markup, say — could only corrupt the row it lands in.
        def newline
          return if @capture
          super
        end

        # Emits *str* as-is, counting it toward the cell width if capturing.
        # For text that is visible but isn't markup content (`#image`'s prefix).
        private def visible(str : String) : Nil
          @capture_width += ::Crysterm::Unicode.display_width(str) if @capture
          literal str
        end

        # --- block elements ----------------------------------------------------

        def heading(node : Markd::Node, entering : Bool) : Nil
          if entering
            blank_line
            level = node.data["level"].as(Int32)
            literal "{bold}{#{Colors.hex @md.heading_color}-fg}"
            literal("#" * level + " ")
          else
            literal "{/#{Colors.hex @md.heading_color}-fg}{/bold}"
            newline
          end
        end

        def paragraph(node : Markd::Node, entering : Bool) : Nil
          if entering
            # Separate top-level paragraphs with a blank line; inside a list item
            # stays tight (just a trailing break).
            blank_line if @lists.empty? && @quote == 0
          else
            newline unless @quote > 0
          end
        end

        def block_quote(node : Markd::Node, entering : Bool) : Nil
          if entering
            blank_line
            @quote += 1
            literal "{#{Colors.hex @md.quote_color}-fg}#{@md.glyph(Glyphs::Role::LineVertical)} "
          else
            @quote -= 1
            literal "{/#{Colors.hex @md.quote_color}-fg}"
            newline
          end
        end

        # A GFM alert (`> [!NOTE] …`) — a blockquote whose first line is a title
        # (the alert name itself when none is given).
        def alert(node : Markd::Node, entering : Bool) : Nil
          color = Colors.hex @md.quote_color
          bar = @md.glyph(Glyphs::Role::LineVertical)
          if entering
            blank_line
            @quote += 1
            literal "{#{color}-fg}#{bar} {bold}"
            text_out node.data["title"].as(String)
            literal "{/bold}{/#{color}-fg}"
            newline
            literal "{#{color}-fg}#{bar} "
          else
            @quote -= 1
            literal "{/#{color}-fg}"
            newline
          end
        end

        def thematic_break(node : Markd::Node, entering : Bool) : Nil
          return unless entering
          blank_line
          literal "{#404a57-fg}" + (@md.glyph(Glyphs::Role::LineHorizontal).to_s * 24) + "{/#404a57-fg}"
          newline
        end

        # *formatter* is `markd`'s optional syntax highlighter; unused, but part
        # of the abstract signature.
        def code_block(node : Markd::Node, entering : Bool, formatter : T?) : Nil forall T
          return unless entering
          blank_line
          node.text.chomp.each_line do |line|
            literal "{#{Colors.hex @md.code_bg}-bg}{#{Colors.hex @md.code_color}-fg}  "
            text_out line
            literal "  {/#{Colors.hex @md.code_color}-fg}{/#{Colors.hex @md.code_bg}-bg}"
            newline
          end
        end

        def list(node : Markd::Node, entering : Bool) : Nil
          if entering
            # Space a top-level list from the prior block — but not from another
            # list: markd splits task items and plain bullets into separate
            # `List`s (`list_match?` compares `type`), and adjacent lists should
            # still read as one.
            blank_line if @lists.empty? && !node.prev?.try(&.type.list?)
            # Explicitly `== "ordered"`, not `!= "bullet"`: a checkbox list is
            # neither, and would otherwise number itself.
            ordered = node.data["type"]? == "ordered"
            start = (node.data["start"]?.try &.as(Int32)) || 1
            @lists << {ordered: ordered, counter: start}
          else
            @lists.pop?
            newline
          end
        end

        def item(node : Markd::Node, entering : Bool) : Nil
          return unless entering
          return if @lists.empty?
          depth = @lists.size - 1
          literal "  " * depth
          # A task item (`- [ ] …` / `- [x] …`) gets a checkbox instead of a
          # bullet; markd has consumed the `[ ]`/`[x]` marker itself.
          if node.data["type"]? == "checkbox"
            if node.data["checked"]? == true
              literal "{#{Colors.hex @md.quote_color}-fg}☑{/#{Colors.hex @md.quote_color}-fg} "
            else
              literal "{#808a96-fg}☐{/#808a96-fg} "
            end
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

        def text(node : Markd::Node, entering : Bool) : Nil
          return unless entering
          text_out node.text
        end

        def strong(node : Markd::Node, entering : Bool) : Nil
          literal(entering ? "{bold}" : "{/bold}")
        end

        def emphasis(node : Markd::Node, entering : Bool) : Nil
          literal(entering ? "{italic}" : "{/italic}")
        end

        def strikethrough(node : Markd::Node, entering : Bool) : Nil
          literal(entering ? "{strike}" : "{/strike}")
        end

        def code(node : Markd::Node, entering : Bool) : Nil
          return unless entering
          literal "{#{Colors.hex @md.code_bg}-bg}{#{Colors.hex @md.code_color}-fg}"
          text_out node.text
          literal "{/#{Colors.hex @md.code_color}-fg}{/#{Colors.hex @md.code_bg}-bg}"
        end

        def link(node : Markd::Node, entering : Bool) : Nil
          if entering
            @link_url = node.data["destination"]?.try &.as(String)
            @link_text = ""
            literal "{underline}{#{Colors.hex @md.link_color}-fg}"
          else
            literal "{/#{Colors.hex @md.link_color}-fg}{/underline}"
            if url = @link_url
              @links << Link.new(@link_text, url)
            end
            @link_url = nil
          end
        end

        def image(node : Markd::Node, entering : Bool) : Nil
          # Prefix the alt text since the image itself can't render inline. The
          # prefix is visible, so it counts toward a cell's width.
          if entering
            literal "{#808a96-fg}"
            visible "🖼 "
          else
            literal "{/#808a96-fg}"
          end
        end

        def soft_break(node : Markd::Node, entering : Bool) : Nil
          # Soft wrap becomes a space; the widget re-wraps to its width.
          visible " " if entering
        end

        def line_break(node : Markd::Node, entering : Bool) : Nil
          newline if entering
        end

        def html_block(node : Markd::Node, entering : Bool) : Nil
          return unless entering
          text_out node.text
          newline
        end

        def html_inline(node : Markd::Node, entering : Bool) : Nil
          text_out node.text if entering
        end

        # --- helpers -----------------------------------------------------------

        # Emits document text: escapes crysterm's `{`/`}` tags, captures the link
        # label while inside a link, and counts the text toward the cell width
        # while inside a table cell (*str* is still unescaped here, so its width
        # is the visible one — `{open}`/`{close}` are one column each).
        private def text_out(str : String) : Nil
          @link_text += str unless @link_url.nil?
          @capture_width += ::Crysterm::Unicode.display_width(str) if @capture
          literal str.gsub(/[{}]/) { |s| s == "{" ? "{open}" : "{close}" }
        end

        # Ensures a blank line precedes the next block, except before the very
        # first block (nothing emitted yet).
        private def blank_line : Nil
          return unless @emitted
          newline
          literal "\n"
        end

        # --- GFM tables (rendered as box-drawing text) -------------------------

        # A table can't be drawn as it is walked: the column widths aren't known
        # until every row has been seen. So the cells are rendered into a buffer
        # (see `#literal`) and the whole table painted on the way out.

        def table(node : Markd::Node, entering : Bool) : Nil
          if entering
            @rows.clear
            @aligns.clear
          else
            paint_table
            @rows.clear
            @aligns.clear
          end
        end

        def table_row(node : Markd::Node, entering : Bool) : Nil
          if entering
            @row = [] of {String, Int32}
          else
            @rows << {cells: @row, heading: node.data["heading"]? == true}
          end
        end

        def table_cell(node : Markd::Node, entering : Bool) : Nil
          if entering
            # Alignment is a property of the column, and markd puts it on every
            # cell; read it off the header row once.
            @aligns << (node.data["align"]?.try(&.as(String)) || "") if node.data["heading"]? == true
            @capture = String::Builder.new
            @capture_width = 0
          else
            cap, @capture = @capture, nil
            @row << {cap.try(&.to_s) || "", @capture_width}
          end
        end

        # Draws the collected rows as a bordered, column-aligned table.
        private def paint_table : Nil
          cols = @rows.first?.try(&.[:cells].size) || 0
          return if cols == 0

          widths = Array.new(cols, 0)
          @rows.each do |row|
            row[:cells].each_with_index do |(_, vis), i|
              widths[i] = Math.max(widths[i], vis) if i < cols
            end
          end

          heading, body = @rows.partition &.[:heading]

          blank_line
          tier = @md.glyph_tier
          table_border widths, Glyphs[Glyphs::Role::BorderLineTL, tier],
            Glyphs[Glyphs::Role::JunctionTeeTop, tier], Glyphs[Glyphs::Role::BorderLineTR, tier]
          heading.each { |row| table_data_row row, widths }
          unless body.empty?
            table_border widths, Glyphs[Glyphs::Role::JunctionTeeLeft, tier],
              Glyphs[Glyphs::Role::JunctionCross, tier], Glyphs[Glyphs::Role::JunctionTeeRight, tier]
            body.each { |row| table_data_row row, widths }
          end
          table_border widths, Glyphs[Glyphs::Role::BorderLineBL, tier],
            Glyphs[Glyphs::Role::JunctionTeeBottom, tier], Glyphs[Glyphs::Role::BorderLineBR, tier]
        end

        private def table_border(widths : Array(Int32), l : Char, mid : Char, r : Char) : Nil
          literal "{#404a57-fg}"
          literal l.to_s
          h = @md.glyph(Glyphs::Role::LineHorizontal).to_s
          widths.each_with_index do |w, i|
            literal h * (w + 2)
            literal(i == widths.size - 1 ? r.to_s : mid.to_s)
          end
          literal "{/#404a57-fg}"
          newline
        end

        private def table_data_row(row : {cells: Array({String, Int32}), heading: Bool},
                                   widths : Array(Int32)) : Nil
          v = @md.glyph(Glyphs::Role::LineVertical)
          bold = row[:heading]
          literal "{#404a57-fg}#{v}{/#404a57-fg}"
          widths.each_with_index do |w, i|
            rendered, vis = row[:cells][i]? || {"", 0}
            literal " "
            literal "{bold}" if bold
            emit_cell rendered, w, vis, @aligns[i]? || ""
            literal "{/bold}" if bold
            literal " {#404a57-fg}#{v}{/#404a57-fg}"
          end
          newline
        end

        # Emits an already-rendered cell padded to *width*. The padding goes
        # outside the cell's tags — the string is styled markup, so it can't be
        # measured or padded as text (that's what *vis* is for).
        private def emit_cell(rendered : String, width : Int32, vis : Int32, align : String) : Nil
          pad = Math.max(0, width - vis)
          left, right = case align
                        when "right"  then {pad, 0}
                        when "center" then {pad // 2, pad - pad // 2}
                        else               {0, pad}
                        end
          literal " " * left
          literal rendered
          literal " " * right
        end
      end
    end
  end
end
