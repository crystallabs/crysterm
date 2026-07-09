require "html5"

module Crysterm
  # HTML-subset import/export for `TextDocument` (TEXTEDIT.md Phase 3) — the
  # `QTextDocument::setHtml`/`toHtml` counterpart, parsed with the `html5`
  # shard (already a dependency of the CSS subsystem).
  #
  # Supported on import: `p div h1..h6 b/strong i/em u/ins s/strike/del a[href]
  # br hr ul ol li pre code/tt/kbd/samp blockquote span[style] font[color]`,
  # plus the style properties `color`, `background(-color)`, `font-weight`,
  # `font-style`, `text-decoration(-line)`, `text-align` and `white-space:
  # pre*`; the `align` attribute works too. Unknown elements are transparent
  # (children walked); `script`/`style`/`head` subtrees are skipped. Tables
  # parse in Phase 4.
  #
  # Whitespace collapses HTML-style (runs → one space, block-edge trimmed)
  # except under `pre` or a `white-space: pre*` block — which the exporter
  # emits whenever a block's text carries significant spaces, so structural
  # prefixes (list indents) round-trip.
  #
  # The block model matches `TextMarkdown`'s Phase-3 approximations (list
  # markers/quote prefixes as literal text, code blocks as code-bg rows), so
  # documents cross-convert consistently. Unlike markdown, HTML spacing is
  # explicit: `<p>a</p><p>b</p>` imports as two *adjacent* blocks and an
  # empty `<p></p>` is the blank separator — `to_html` emits exactly that,
  # keeping round-trips stable. `dim`/`inverse`/`blink` have no HTML form and
  # are dropped on export.
  module TextHtml
    WS_RUN = /[ \t\r\n\f]+/

    # Parses an HTML document or fragment into detached blocks.
    def self.parse(html : String, theme : TextTheme = TextTheme.default) : Array(TextBlock)
      Importer.new(theme).import(html)
    end

    # Serializes *blocks* to HTML (a body fragment, one element per block).
    def self.generate(blocks : Array(TextBlock)) : String
      String.build do |io|
        blocks.each_with_index do |b, i|
          io << '\n' if i > 0
          bf = b.block_format
          lvl = bf.heading_level
          tag = lvl > 0 ? "h#{lvl.clamp(1, 6)}" : "p"
          style = block_style(bf, b)
          io << '<' << tag
          io << " style=\"" << style << '"' unless style.empty?
          io << '>'
          b.fragments.each { |f| write_fragment(io, f) }
          io << "</" << tag << '>'
        end
      end
    end

    private def self.block_style(bf : TextBlockFormat, b : TextBlock) : String
      props = [] of String
      if a = bf.alignment
        name = a.h_center? ? "center" : (a.right? ? "right" : (a.left? ? "left" : nil))
        props << "text-align:#{name}" if name
      end
      if (bg = bf.bg) && bg >= 0
        props << "background-color:#{hex(bg)}"
      end
      # Significant whitespace (list indents, aligned columns) must survive
      # the reader's HTML collapsing.
      props << "white-space:pre-wrap" if b.text.matches?(/\A |  | \z/)
      props.join(';')
    end

    private def self.write_fragment(io : IO, f : TextFragment) : Nil
      fmt = f.format
      closers = [] of String
      if url = fmt.anchor_href
        io << "<a href=\"" << escape_attr(url) << "\">"
        closers << "</a>"
      end
      span = String.build do |s|
        if (c = fmt.fg) && c >= 0
          s << "color:" << hex(c)
        end
        if (c = fmt.bg) && c >= 0
          s << ';' unless s.empty?
          s << "background-color:" << hex(c)
        end
      end
      unless span.empty?
        io << "<span style=\"" << span << "\">"
        closers << "</span>"
      end
      {% for a, tag in {bold: "b", italic: "i", underline: "u", strike: "s", code: "code"} %}
        if fmt.{{a.id}}?
          io << "<{{tag.id}}>"
          closers << "</{{tag.id}}>"
        end
      {% end %}
      io << escape_html(f.text)
      closers.reverse_each { |t| io << t }
    end

    private def self.hex(color : Int32) : String
      "##{color.to_s(16).rjust(6, '0')}"
    end

    private def self.escape_html(text : String) : String
      text.gsub('&', "&amp;").gsub('<', "&lt;").gsub('>', "&gt;")
    end

    private def self.escape_attr(text : String) : String
      escape_html(text).gsub('"', "&quot;")
    end

    # DOM → blocks. Same shape as `TextMarkdown::Importer`: a patch stack for
    # inline formats, literal quote/list prefixes, code-bg code blocks.
    private class Importer
      @blocks = [] of TextBlock
      @frags = [] of TextFragment
      @block_format : TextBlockFormat = TextBlockFormat.default
      @block_open = false
      # Whether the open block collapses whitespace (false under
      # `white-space: pre*`).
      @collapse = true
      @patches = [] of TextCharFormat
      @fmt : TextCharFormat?
      @quote_depth = 0
      @lists = [] of {ordered: Bool, counter: Int32}
      @pending_marker : {String, TextCharFormat}?

      def initialize(@theme : TextTheme)
      end

      def import(html : String) : Array(TextBlock)
        doc = HTML5.parse(html)
        if body = find_body(doc)
          walk_children(body)
        end
        end_block
        @blocks.empty? ? [TextBlock.new] : @blocks
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

        case node.data
        when "p", "div"
          bf, collapse = block_format_from(node)
          end_block
          start_block(bf, collapse)
          walk_children(node)
          end_block
        when "h1", "h2", "h3", "h4", "h5", "h6"
          lvl = node.data[1].to_i
          bf, collapse = block_format_from(node, heading: lvl)
          end_block
          start_block(bf, collapse)
          with_patch(TextCharFormat.new(fg: @theme.heading_color)) { walk_children(node) }
          end_block
        when "br"
          bf = @block_format
          collapse = @collapse
          end_block
          start_block(bf, collapse)
        when "hr"
          end_block
          start_block
          @frags << TextFragment.new(TextMarkdown.rule_text, TextCharFormat.new(fg: @theme.rule_color))
          end_block
        when "pre"
          end_block
          bf = TextBlockFormat.new(bg: @theme.code_bg)
          fmt = TextCharFormat.new(code: true, fg: @theme.code_color)
          plain_text_of(node).lchop('\n').chomp.split('\n').each do |line|
            start_block(bf, collapse: false)
            @frags << TextFragment.new(line, fmt) unless line.empty?
            end_block
          end
        when "blockquote"
          end_block
          @quote_depth += 1
          walk_children(node)
          @quote_depth -= 1
          end_block
        when "ul", "ol"
          end_block
          start = attr_val(node, "start").try(&.to_i?) || 1
          @lists << {ordered: node.data == "ol", counter: start}
          walk_children(node)
          @lists.pop?
        when "li"
          end_block
          set_item_marker
          start_block
          walk_children(node)
          end_block
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
        when "script", "style", "head", "template", "title"
          # skipped subtrees
        else
          walk_children(node)
        end
      end

      # === Block assembly (see `TextMarkdown::Importer`) ===

      private def start_block(bf : TextBlockFormat = TextBlockFormat.default, collapse : Bool = true) : Nil
        @frags = [] of TextFragment
        @block_format = bf
        @collapse = collapse
        @block_open = true
        if @quote_depth > 0
          qfmt = TextCharFormat.new(fg: @theme.quote_color)
          @frags << TextFragment.new(TextMarkdown.quote_prefix * @quote_depth, qfmt)
        end
        if pm = @pending_marker
          @frags << TextFragment.new(pm[0], pm[1])
          @pending_marker = nil
        end
      end

      private def ensure_block : Nil
        start_block unless @block_open
      end

      private def end_block : Nil
        return unless @block_open
        if @collapse && (last = @frags.last?)
          last.text = last.text.rstrip(' ')
          @frags.pop if last.text.empty?
        end
        @blocks << TextBlock.new(@frags, @block_format)
        @frags = [] of TextFragment
        @block_format = TextBlockFormat.default
        @block_open = false
      end

      private def set_item_marker : Nil
        indent = "  " * (@lists.size - 1)
        cur = @lists.last?
        if cur && cur[:ordered]
          @pending_marker = {indent + "#{cur[:counter]}. ", TextCharFormat.new(fg: @theme.heading_color)}
          @lists[-1] = {ordered: true, counter: cur[:counter] + 1}
        else
          @pending_marker = {indent + "• ", TextCharFormat.new(fg: @theme.heading_color)}
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

      private def append_text(str : String) : Nil
        return if str.empty?
        if @block_open && !@collapse
          @frags << TextFragment.new(str.gsub('\n', ' '), current_format)
          return
        end
        s = str.gsub(TextHtml::WS_RUN, " ")
        if s.starts_with?(' ') && boundary_space?
          s = s.lstrip(' ')
        end
        return if s.empty?
        ensure_block
        @frags << TextFragment.new(s, current_format)
      end

      # Whether a leading space would be redundant here: block boundary, or
      # the previous run already ends in one.
      private def boundary_space? : Bool
        return true unless @block_open
        last = @frags.last?
        last.nil? || last.text.ends_with?(' ')
      end

      private def plain_text_of(node : HTML5::Node) : String
        String.build { |io| collect_text(node, io) }
      end

      private def collect_text(node : HTML5::Node, io : IO) : Nil
        io << node.data if node.type.text?
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
        collapse = true
        if st = attr_val(node, "style")
          st.split(';').each do |decl|
            k, _, v = decl.partition(':')
            v = v.strip
            case k.strip.downcase
            when "text-align"
              align = align_flag(v.downcase) || align
            when "background-color", "background"
              bg = css_color(v) || bg
            when "white-space"
              collapse = !v.downcase.starts_with?("pre")
            end
          end
        end
        if av = attr_val(node, "align")
          align = align_flag(av.downcase) || align
        end
        bf = TextBlockFormat.new(alignment: align, bg: bg,
          heading_level: heading > 0 ? heading : nil)
        {bf, collapse}
      end

      private def align_flag(name : String) : Tput::AlignFlag?
        case name
        when "left"   then Tput::AlignFlag::Left
        when "center" then Tput::AlignFlag::HCenter
        when "right"  then Tput::AlignFlag::Right
        else               nil
        end
      end

      # Inline-format patch from a `style` attribute, or nil when it sets
      # nothing we model.
      private def style_patch(style : String?) : TextCharFormat?
        return nil unless style
        bold = italic = underline = strike = nil
        fg = bg = nil
        any = false
        style.split(';').each do |decl|
          k, _, v = decl.partition(':')
          v = v.strip
          case k.strip.downcase
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
        return nil unless any
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
