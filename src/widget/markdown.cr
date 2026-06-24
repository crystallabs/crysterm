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
          # Separate top-level paragraphs with a blank line; inside a list item a
          # paragraph stays tight (no blank), just a trailing break.
          if entering
            blank_line if @lists.empty? && @quote == 0
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
          cur = @lists[-1]
          if cur[:ordered]
            literal "{#86B5FF-fg}#{cur[:counter]}.{/#86B5FF-fg} "
            @lists[-1] = {ordered: true, counter: cur[:counter] + 1}
          else
            literal "{#86B5FF-fg}•{/#86B5FF-fg} "
          end
        end

        # --- inline elements ---------------------------------------------------

        def text(node : Markd::Node, entering : Bool)
          return unless entering
          text_out node.text
        end

        def strong(node : Markd::Node, entering : Bool)
          literal(entering ? "{bold}" : "{/bold}")
        end

        def emphasis(node : Markd::Node, entering : Bool)
          literal(entering ? "{italic}" : "{/italic}")
        end

        def code(node : Markd::Node, entering : Bool)
          return unless entering
          literal "{#{hex @md.code_bg}-bg}{#{hex @md.code_color}-fg}"
          text_out node.text
          literal "{/#{hex @md.code_color}-fg}{/#{hex @md.code_bg}-bg}"
        end

        def link(node : Markd::Node, entering : Bool)
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
          literal " " if entering
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

        # Emits literal text, escaping crysterm's `{`/`}` so they aren't read as
        # tags, and capturing it as link label while inside a link.
        private def text_out(str : String) : Nil
          @link_text += str unless @link_url.nil?
          literal str.gsub('{', "{open}").gsub('}', "{close}")
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
      end
    end
  end
end
