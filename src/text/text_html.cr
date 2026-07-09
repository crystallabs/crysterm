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
  # The block model matches `TextMarkdown`'s (Phase-4 structures: `ul`/`ol`
  # → one `TextList` per list element, `blockquote` nesting →
  # `TextBlockFormat#quote_level`, `hr` → a `horizontal_rule` block; code
  # blocks as code-bg rows), so documents cross-convert consistently.
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
      io << "<table>"
      data.each_with_index do |b, ri|
        tag = ri == 0 ? "th" : "td"
        io << "<tr>"
        TextTable.split_data_row(b.text).each do |cell|
          io << '<' << tag << '>' << escape_html(cell) << "</" << tag << '>'
        end
        io << "</tr>"
      end
      io << "</table>"
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
      b.fragments.each { |f| write_fragment(io, f) }
      io << "</" << tag << '>'
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
      # Block spacing as CSS margins (1em = one blank row), so it survives
      # the round-trip into the importer's `margin-*` parsing.
      if (m = bf.top_margin) > 0
        props << "margin-top:#{m}em"
      end
      if (m = bf.bottom_margin) > 0
        props << "margin-bottom:#{m}em"
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
    # inline formats, `TextList`/quote-level/rule block structures, code-bg
    # code blocks.
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
      # Open (nested) list elements; one shared `TextListFormat` instance
      # per `ul`/`ol` — instance identity is list identity.
      @list_stack = [] of TextListFormat
      # List the next `start_block`'s block joins (set by `li`, consumed by
      # the first block opened inside it).
      @pending_item : TextListFormat?
      # Block format parsed off the `li` element itself (margins/alignment),
      # consumed together with `@pending_item`.
      @pending_item_format : TextBlockFormat?
      # Whether the pending `li` is a checked checkbox item (its block's
      # `checked` flag; the `Checkbox` list style comes from the enclosing
      # `<ul>`).
      @pending_checked = false
      # Blank rows owed to the next block's `top_margin` (accumulated from
      # empty spacing `<p></p>`s — the margins re-base).
      @pending_margin = 0

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
          end_block
          start_block(bf, collapse)
          with_patch(TextCharFormat.new(fg: @theme.heading_color)) { walk_children(node) }
          end_block
        when "br"
          bf = @block_format.with_list_format(nil).with_checked(nil)
          collapse = @collapse
          end_block
          start_block(bf, collapse)
        when "hr"
          end_block
          bf, _ = block_format_from(node)
          start_block bf.merge(TextBlockFormat.new(horizontal_rule: true))
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
          @list_stack << TextListFormat.new(
            style: list_style(node),
            indent: @list_stack.size + 1,
            start: start)
          walk_children(node)
          @list_stack.pop?
        when "li"
          end_block
          # Consumed by the first block opened inside the item — directly by
          # its text, or by a wrapping `<p>` (loose lists) — so no eager
          # `start_block` here: it would emit an empty member block.
          @pending_item = @list_stack.last?
          # A checkbox item (`<input type=checkbox>`) stashes its checked
          # state for `start_block`; the input element itself is dropped
          # (void, no text).
          @pending_checked = pending_item_checked?(node)
          # The li's own styles (margins, alignment) ride along.
          ibf, _ = block_format_from(node)
          @pending_item_format = ibf == TextBlockFormat.default ? nil : ibf
          walk_children(node)
          end_block
          @pending_item = nil
          @pending_item_format = nil
          @pending_checked = false
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
        when "table"
          end_block
          import_table(node)
        when "script", "style", "head", "template", "title"
          # skipped subtrees
        else
          walk_children(node)
        end
      end

      # `<table>` → pre-rendered `TextTable` blocks. The first `<th>` row (or
      # the first row) is the header; cell markup degrades to its plain,
      # whitespace-collapsed text.
      private def import_table(node : HTML5::Node) : Nil
        header = nil
        body = [] of Array(String)
        trs = [] of HTML5::Node
        collect_trs(node, trs)
        trs.each do |tr|
          cells = [] of String
          has_th = false
          child = tr.first_child
          while child
            if child.type.element? && (child.data == "td" || child.data == "th")
              has_th = true if child.data == "th"
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
        bs = TextTable.build(header, body, nil, @theme)
        if @pending_margin > 0
          bs[0].block_format = bs[0].block_format.merge(TextBlockFormat.new(top_margin: @pending_margin))
          @pending_margin = 0
        end
        if @quote_depth > 0
          q = TextBlockFormat.new(quote_level: @quote_depth)
          bs.each { |b| b.block_format = b.block_format.merge(q) }
        end
        @blocks.concat(bs)
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

      # === Block assembly (see `TextMarkdown::Importer`) ===

      private def start_block(bf : TextBlockFormat = TextBlockFormat.default, collapse : Bool = true) : Nil
        @frags = [] of TextFragment
        if @pending_margin > 0
          bf = bf.merge(TextBlockFormat.new(top_margin: bf.top_margin + @pending_margin))
          @pending_margin = 0
        end
        bf = bf.merge(TextBlockFormat.new(quote_level: @quote_depth)) if @quote_depth > 0
        if li = @pending_item
          # An item's first block is the list item proper; the li element's
          # own block styles apply under the block's (a loose item's `<p>`
          # wins where both specify).
          if ibf = @pending_item_format
            bf = ibf.merge(bf)
            @pending_item_format = nil
          end
          bf = bf.merge(TextBlockFormat.new(list_format: li))
          bf = bf.merge(TextBlockFormat.new(checked: true)) if @pending_checked
          @pending_item = nil
        elsif !@list_stack.empty?
          # A continuation block inside an item: indent to roughly the item
          # text column (nesting + a 2-cell marker approximation).
          bf = bf.merge(TextBlockFormat.new(indent: @list_stack.size * 2))
        end
        @block_format = bf
        @collapse = collapse
        @block_open = true
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
        mt = mb = nil
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
            when "margin-top"
              mt = css_rows(v) || mt
            when "margin-bottom"
              mb = css_rows(v) || mb
            when "white-space"
              collapse = !v.downcase.starts_with?("pre")
            end
          end
        end
        if av = attr_val(node, "align")
          align = align_flag(av.downcase) || align
        end
        bf = TextBlockFormat.new(alignment: align, bg: bg,
          top_margin: mt, bottom_margin: mb,
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
          rows = n.round.to_i
          rows > 0 ? rows : nil
        end
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
