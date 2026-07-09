module Crysterm
  # Import/export between `TextDocument` content and the toolkit's native tag
  # markup (`{bold}…{/bold}`, `{red-fg}`, `{#rrggbb-bg}` — the vocabulary
  # `Widget#_parse_tags` renders) — the "home" interchange format, standing in
  # for Qt's HTML (TEXTEDIT.md Phase 3). Lossless for the char-format set;
  # newlines separate blocks.
  #
  # Extensions beyond the widget vocabulary (chosen to *degrade cleanly*: all
  # but `{link=…}` match the widget's `TAG_REGEX`, so `_parse_tags` drops them
  # silently instead of leaking text):
  #
  # - `{!block;prop;…}` — block-format prefix, conventionally at the start of
  #   its line. Props: `h1`..`h6` (heading level), `align-left|center|right`,
  #   `indent-N`, `mt-N`/`mb-N` (top/bottom margin), `bg-<color>`, `nobreak`,
  #   `q-N` (quote level), `hr` (horizontal rule), and lists:
  #   `list-<style>` (disc|circle|square|decimal|loweralpha|upperalpha|
  #   lowerroman|upperroman) with optional `li-N` (nesting level) and `ls-N`
  #   (numbering start). *Consecutive* blocks with identical list props join
  #   one `TextList`; a non-list block in between splits it (two adjacent
  #   distinct lists with equal props therefore merge on a round-trip).
  #   Number prefix/suffix are not serialized.
  # - Alignment additionally round-trips through the widget-native
  #   `{center}…{/center}` / `{right}…{/right}` wrapping tags (the export
  #   form, since widgets understand it).
  # - `{link=URL}…{/link}` — anchors (`{`/`}` in the URL percent-encoded).
  #   The one form `_parse_tags` does NOT match; feeding it to a plain widget
  #   leaks the tag text, so strip links first if that matters.
  # - `{dim}`/`{code}` — flags without a widget/SGR rendering today; parsed
  #   and stored (`code` is the semantic verbatim marker).
  #
  # Unknown tags and stray braces are dropped (the widget's drop-malformed
  # policy); `{open}`/`{close}` emit literal braces; `{escape}…{/escape}`
  # passes verbatim; `{/}` resets all char formats. `{|}` (the right-align
  # separator) has no document representation and is dropped.
  module TextTags
    # Same shape as `Widget::TAG_REGEX` (duplicated so the document framework
    # stands alone, like `TextDocument.word_char?`).
    TAG_REGEX  = /\{(\/?)([\w\-,;!#]*)\}/
    LINK_REGEX = /\{link=([^}]*)\}/

    # Boolean-attribute tag names (aliases match `Tput#_attr`'s).
    FLAG_NAMES = {
      "bold"          => TextCharFormat::Attr::Bold,
      "italic"        => TextCharFormat::Attr::Italic,
      "underline"     => TextCharFormat::Attr::Underline,
      "ul"            => TextCharFormat::Attr::Underline,
      "underlined"    => TextCharFormat::Attr::Underline,
      "strike"        => TextCharFormat::Attr::Strike,
      "strikethrough" => TextCharFormat::Attr::Strike,
      "crossed"       => TextCharFormat::Attr::Strike,
      "crossed_out"   => TextCharFormat::Attr::Strike,
      "inverse"       => TextCharFormat::Attr::Inverse,
      "reverse"       => TextCharFormat::Attr::Inverse,
      "dim"           => TextCharFormat::Attr::Dim,
      "blink"         => TextCharFormat::Attr::Blink,
      "code"          => TextCharFormat::Attr::Code,
    }

    # Canonical open-tag name per attribute, in emission order.
    FLAG_ORDER = [
      {TextCharFormat::Attr::Bold, "bold"},
      {TextCharFormat::Attr::Italic, "italic"},
      {TextCharFormat::Attr::Underline, "underline"},
      {TextCharFormat::Attr::Strike, "strike"},
      {TextCharFormat::Attr::Inverse, "inverse"},
      {TextCharFormat::Attr::Dim, "dim"},
      {TextCharFormat::Attr::Blink, "blink"},
      {TextCharFormat::Attr::Code, "code"},
    ]

    # Parses tag markup into detached blocks.
    def self.parse(text : String) : Array(TextBlock)
      Parser.new.parse(text)
    end

    # Serializes *blocks* to tag markup; `parse(generate(b))` restores the
    # same appearance.
    def self.generate(blocks : Array(TextBlock)) : String
      String.build do |io|
        blocks.each_with_index do |b, i|
          io << '\n' if i > 0
          bf = b.block_format
          write_block_prefix(io, bf)
          wrap = align_name(bf.alignment)
          io << '{' << wrap << '}' if wrap
          b.fragments.each { |f| write_fragment(io, f) }
          io << "{/" << wrap << '}' if wrap
        end
      end
    end

    private def self.align_name(a : Tput::AlignFlag?) : String?
      return nil unless a
      return "center" if a.h_center?
      return "right" if a.right?
      return "left" if a.left?
      nil
    end

    private def self.write_block_prefix(io : IO, bf : TextBlockFormat) : Nil
      props = [] of String
      props << "h#{bf.heading_level}" if bf.heading_level > 0
      props << "indent-#{bf.indent}" if bf.indent > 0
      props << "mt-#{bf.top_margin}" if bf.top_margin > 0
      props << "mb-#{bf.bottom_margin}" if bf.bottom_margin > 0
      if (bg = bf.bg) && bg >= 0
        props << "bg-#{hex(bg)}"
      end
      props << "nobreak" if bf.non_breakable?
      props << "q-#{bf.quote_level}" if bf.quote_level > 0
      props << "hr" if bf.horizontal_rule?
      if lf = bf.list_format
        props << "list-#{lf.style.to_s.downcase}"
        props << "li-#{lf.indent}" if lf.indent != 1
        props << "ls-#{lf.start}" if lf.start != 1
      end
      io << "{!block;" << props.join(';') << '}' unless props.empty?
    end

    private def self.write_fragment(io : IO, f : TextFragment) : Nil
      fmt = f.format
      closers = [] of String
      if url = fmt.anchor_href
        io << "{link=" << url.gsub('{', "%7B").gsub('}', "%7D") << '}'
        closers << "{/link}"
      end
      # An explicit `-1` ("terminal default") is visually the unset base
      # attr — emit nothing, so it degrades to `nil` on re-parse.
      if (c = fmt.fg) && c >= 0
        io << '{' << hex(c) << "-fg}"
        closers << "{/#{hex(c)}-fg}"
      end
      if (c = fmt.bg) && c >= 0
        io << '{' << hex(c) << "-bg}"
        closers << "{/#{hex(c)}-bg}"
      end
      FLAG_ORDER.each do |(attr, name)|
        if fmt.attributes.includes?(attr)
          io << '{' << name << '}'
          closers << "{/#{name}}"
        end
      end
      text = f.text
      # Single pass: sequential gsubs would re-escape the braces of the
      # `{open}`/`{close}` replacements themselves.
      text = text.gsub(/[{}]/) { |s| s == "{" ? "{open}" : "{close}" } if text.includes?('{') || text.includes?('}')
      io << text
      closers.reverse_each { |t| io << t }
    end

    private def self.hex(color : Int32) : String
      "##{color.to_s(16).rjust(6, '0')}"
    end

    # The import state machine — the `_parse_tags` loop re-targeted from SGR
    # strings to fragments/blocks. Char-format state is proper per-category:
    # depth counters per boolean attribute (so nesting the same flag twice
    # needs two closes) and stacks for fg/bg/link (a close restores the
    # enclosing value).
    private class Parser
      @blocks = [] of TextBlock
      @frags = [] of TextFragment
      @block_format : TextBlockFormat = TextBlockFormat.default
      @depth = Hash(TextCharFormat::Attr, Int32).new(0)
      @fg = [] of Int32
      @bg = [] of Int32
      @links = [] of String
      @aligns = [] of Tput::AlignFlag
      # Cached current format; any state change invalidates.
      @fmt : TextCharFormat?
      # Open list run (see `#list_instance`).
      @cur_list : TextListFormat?
      @cur_list_spec : {TextListFormat::Style, Int32, Int32}?

      def parse(text : String) : Array(TextBlock)
        anchored = Regex::MatchOptions::ANCHORED
        has_escape = text.includes?("{escape}")
        has_bar = text.includes?("{|}")
        esc = false
        pos = 0
        size = text.size

        while pos < size
          if has_escape
            if !esc && (cap = /\{escape\}/.match(text, pos, options: anchored))
              pos += cap[0].size
              esc = true
              next
            end
            if esc && (cap = /([\s\S]+?)\{\/escape\}/.match(text, pos, options: anchored))
              pos += cap[0].size
              append_text cap[1]
              esc = false
              next
            end
            if esc
              # Unterminated escape: the rest is verbatim (matches `_parse_tags`).
              append_text text[pos..]
              break
            end
          end

          if has_bar && text[pos, 3]? == "{|}"
            pos += 3
            next
          end

          if cap = TextTags::LINK_REGEX.match(text, pos, options: anchored)
            pos += cap[0].size
            @links << cap[1].gsub("%7B", "{").gsub("%7D", "}")
            @fmt = nil
            next
          end

          if cap = TextTags::TAG_REGEX.match(text, pos, options: anchored)
            pos += cap[0].size
            handle_tag !cap[1].empty?, cap[2]
            next
          end

          b1 = text.index('{', pos)
          b2 = text.index('}', pos)
          nb = b1 ? (b2 ? Math.min(b1, b2) : b1) : (b2 || size)
          if nb > pos
            append_text text[pos...nb]
            pos = nb
            next
          end

          # A lone brace that began no recognized tag: dropped.
          pos += 1
        end

        finish_block
        @blocks
      end

      private def handle_tag(slash : Bool, param : String) : Nil
        if param.blank?
          return unless slash
          # `{/}` resets every char format.
          @depth.clear
          @fg.clear
          @bg.clear
          @links.clear
          @fmt = nil
          return
        end

        case param
        when "open"
          append_text "{"
          return
        when "close"
          append_text "}"
          return
        when "link"
          # Only the closer reaches here (`{link=…}` matched earlier).
          @links.pop? if slash
          @fmt = nil
          return
        when "left", "center", "right"
          if slash
            @aligns.pop?
          else
            af = param == "center" ? Tput::AlignFlag::HCenter : (param == "right" ? Tput::AlignFlag::Right : Tput::AlignFlag::Left)
            @aligns << af
            @block_format = @block_format.merge(TextBlockFormat.new(alignment: af))
          end
          return
        end

        if param.starts_with?("!block")
          apply_block_props(param) unless slash
          return
        end

        if param.ends_with?("-fg") || param.ends_with?("-bg")
          stack = param.ends_with?("-fg") ? @fg : @bg
          if slash
            stack.pop?
            @fmt = nil
          elsif c = parse_color(param[0...-3])
            stack << c
            @fmt = nil
          end
          return
        end

        if attr = TextTags::FLAG_NAMES[param]?
          if slash
            @depth[attr] -= 1 if @depth[attr] > 0
          else
            @depth[attr] += 1
          end
          @fmt = nil
        end
        # else: unrecognized tag — dropped.
      end

      private def apply_block_props(spec : String) : Nil
        heading = indent = mt = mb = bg = quote = nil
        align = nil
        nobreak = hr = nil
        list_style = nil
        list_indent = 1
        list_start = 1
        spec.split(';').each_with_index do |prop, i|
          next if i == 0 # the "!block" marker itself
          case prop
          when /\Ah([1-6])\z/     then heading = $1.to_i
          when "align-left"       then align = Tput::AlignFlag::Left
          when "align-center"     then align = Tput::AlignFlag::HCenter
          when "align-right"      then align = Tput::AlignFlag::Right
          when /\Aindent-(\d+)\z/ then indent = $1.to_i
          when /\Amt-(\d+)\z/     then mt = $1.to_i
          when /\Amb-(\d+)\z/     then mb = $1.to_i
          when /\Abg-(.+)\z/      then bg = parse_color($1)
          when "nobreak"          then nobreak = true
          when /\Aq-(\d+)\z/      then quote = $1.to_i
          when "hr"               then hr = true
          when /\Alist-(\w+)\z/   then list_style = TextListFormat::Style.parse?($1)
          when /\Ali-(\d+)\z/     then list_indent = $1.to_i
          when /\Als-(\d+)\z/     then list_start = $1.to_i
          end
        end
        lf = list_style ? list_instance(list_style, list_indent, list_start) : nil
        @block_format = @block_format.merge(TextBlockFormat.new(
          alignment: align, indent: indent, top_margin: mt, bottom_margin: mb,
          bg: bg, heading_level: heading, non_breakable: nobreak,
          quote_level: quote, horizontal_rule: hr, list_format: lf))
      end

      # Consecutive blocks with identical list props share one
      # `TextListFormat` instance — that IS list identity; a finished block
      # without list props resets the run (see `#finish_block`).
      private def list_instance(style : TextListFormat::Style, indent : Int32, start : Int32) : TextListFormat
        spec = {style, indent, start}
        if (cur = @cur_list) && @cur_list_spec == spec
          cur
        else
          @cur_list_spec = spec
          @cur_list = TextListFormat.new(style: style, indent: indent, start: start)
        end
      end

      # `nil` = unknown color (tag dropped); `-1` only for the explicit
      # `default`. Multi-word tag names use dashes (`light-blue`), TermColors
      # names are squashed (`lightblue`).
      private def parse_color(spec : String) : Int32?
        return -1 if spec == "default"
        c = Colors.convert_cached(spec.starts_with?('#') ? spec : spec.delete('-'))
        c == -1 ? nil : c
      end

      private def current_format : TextCharFormat
        @fmt ||= begin
          attrs = TextCharFormat::Attr::None
          @depth.each { |a, d| attrs |= a if d > 0 }
          TextCharFormat.new(attrs, attrs, @fg.last?, @bg.last?, @links.last?)
        end
      end

      private def append_text(str : String) : Nil
        return if str.empty?
        if str.includes?('\n')
          parts = str.split('\n')
          parts.each_with_index do |part, i|
            finish_block if i > 0
            @frags << TextFragment.new(part, current_format) unless part.empty?
          end
        else
          @frags << TextFragment.new(str, current_format)
        end
      end

      private def finish_block : Nil
        @blocks << TextBlock.new(@frags, @block_format)
        # A block without list props ends the current list run — the next
        # list block starts a fresh `TextList`.
        @cur_list = @cur_list_spec = nil if @block_format.list_format.nil?
        @frags = [] of TextFragment
        # A still-open alignment tag carries into the next block.
        @block_format = (af = @aligns.last?) ? TextBlockFormat.new(alignment: af) : TextBlockFormat.default
      end
    end
  end

  class TextDocument
    # Builds a document from tag markup (see `TextTags`).
    def self.from_tags(text : String) : TextDocument
      doc = TextDocument.new
      doc.set_tags(text)
      doc
    end

    # Replaces the whole content from tag markup. Same reset semantics as
    # `set_plain_text` (not undoable, cursors rewind).
    def set_tags(text : String) : Nil
      replace_content(TextTags.parse(text))
    end

    # The content as tag markup (see `TextTags`).
    def to_tags : String
      TextTags.generate(blocks)
    end
  end

  class TextDocumentFragment
    # Builds a detached fragment from tag markup (see `TextTags`).
    def self.from_tags(text : String) : TextDocumentFragment
      new(TextTags.parse(text))
    end

    # The fragment as tag markup (see `TextTags`).
    def to_tags : String
      TextTags.generate(@blocks)
    end
  end
end
