module Crysterm
  class Widget
    include Helpers

    # module Content

    # Convenience regex for matching Crysterm tags and their content (i.e. '{bold}This text is bold{/bold}').
    TAG_REGEX = /\{(\/?)([\w\-,;!#]*)\}/

    # Convenience regex for matching SGR sequences.
    SGR_REGEX = /\e\[[\d;]*m/

    # :ditto:
    SGR_REGEX_AT_BEGINNING = /^#{SGR_REGEX}/

    # Can element's content be word-wrapped?
    property? wrap_content = true

    # Is element's content to be parsed for tags?
    property? parse_tags = false

    # Alignment of contained text
    Crystallabs::Helpers::Enums.enum_property align : Tput::AlignFlag = Tput::AlignFlag::Top | Tput::AlignFlag::Left

    # Widget's user-set content in original form. Includes any attributes and tags.
    getter content : String = ""

    # Printable, word-wrapped content, ready for rendering into the element.
    property _pcontent : String?

    # Cached codepoint index over `@_pcontent`, reused across frames. `_render`
    # indexes content per cell, so for non-ASCII content the index materializes a
    # `chars` array; rebuilding it every frame is pure per-frame garbage. It is
    # rebuilt only when `@_pcontent` becomes a different `String` (i.e. on a
    # content reparse — see `StringIndex#built_from?`).
    @_content_index : StringIndex? = nil

    property _clines = CLines.new

    # Bumped every time `@content` changes (see `set_content`). `process_content`
    # compares this integer against the version baked into `@_clines` to decide
    # whether a reparse is needed, instead of doing an O(n) `String` comparison
    # of the full content on every render.
    @_content_version = 0

    # The `sattr(style)` value that the currently-cached `@_clines.attr` was
    # computed against. `_parse_attr` only depends on the content (unchanged on
    # the cached path) and this base attribute, so it can be skipped whenever the
    # style's packed attr is unchanged frame-to-frame (the common case). `nil`
    # forces the first computation.
    @_parse_attr_default : Int64? = nil

    # Processes and sets widget content. Does not allow extra options re.
    # how content is to be processed; use `#set_content` if you need to provide
    # extra options.
    def content=(content)
      set_content content
    end

    def set_content(content = "", no_clear = false, no_tags = false)
      # Previously this erased the widget's last-rendered footprint (unless
      # `no_clear`) so that shrinking content wouldn't leave stale cells behind.
      # That is now handled centrally: `Screen#_render` clears the whole cell
      # buffer before each frame. `no_clear` is kept for call compatibility.

      # XXX make it possible to have `update_context`, which only updates
      # internal structures, not @content (for rendering purposes, where
      # original content should not be modified).
      @content = content
      @_content_version += 1

      process_content(no_tags)
      emit(Crysterm::Event::SetContent)
    end

    def get_content
      return "" if @_clines.empty?
      @_clines.fake.join "\n"
    end

    def set_text(content = "", no_clear = false)
      content = content.gsub SGR_REGEX, ""
      set_content content, no_clear, true
    end

    def get_text
      get_content.gsub SGR_REGEX, ""
    end

    # Word-wrapped, ready-to-render content lines plus the bookkeeping needed
    # to map between the original ("fake") and wrapped ("real") line numbers.
    #
    # This used to subclass `Array(String)`. Subclassing a stdlib generic is
    # deprecated, and—more importantly—it promotes every `Array(String)` in the
    # whole program (including in unrelated shards) to the virtual type
    # `Array(String)+`, which produces confusing compile errors far away from
    # here (see issue #30). It now *wraps* an array and forwards the array API
    # to it via `forward_missing_to`, so no `Array(String)` is ever subclassed.
    class CLines
      property string = ""
      property max_width = 0
      property width = 0

      property content : String = ""

      # Version of the owning widget's `@content` that produced these wrapped
      # lines. Defaults to -1 so a freshly-built `CLines` never matches a real
      # (>= 0) widget content version, forcing the first parse. See
      # `Widget#process_content`.
      property content_version : Int32 = -1

      property real : CLines? = nil

      property fake = [] of String

      property ftor = [] of Array(Int32)
      property rtof = [] of Int32
      property ci = [] of Int32

      # Defaults to `nil` (not an empty array): `process_content` always replaces
      # this with `_parse_attr`'s result on a reparse before the lines are used,
      # so pre-allocating an array here is pure per-reparse waste. All readers go
      # through `attr.try(...)`, so `nil` is handled.
      property attr : Array(Int64)? = nil

      # Backing store of wrapped lines. The array API (`push`, `[]`, `size`,
      # `each`, `join`, `reduce`, ...) is forwarded to it below.
      getter lines : Array(String)

      def initialize(@lines = [] of String)
      end

      # Clears the arrays a reparse refills in place (`#lines`, `rtof`, `ftor`,
      # `ci`) so this same `CLines` can be reused by the next `_wrap_content`
      # instead of allocating a fresh object + arrays every reparse. `clear`
      # keeps each array's backing buffer, so steady-state reparsing of
      # same-shaped content reallocates nothing here. `fake`/`attr`/`real` and
      # the scalar fields are overwritten wholesale by the reparse, so they are
      # not touched. (`ftor`'s per-line sub-arrays are dropped and rebuilt; only
      # the outer array's buffer is retained.)
      def reset : Nil
        @lines.clear
        @rtof.clear
        @ftor.clear
        @ci.clear
      end

      # Match the old `Array#dup` behavior: a fresh, independent `Array(String)`
      # copy (without the extra bookkeeping). Defined explicitly because
      # `dup` already exists on `Object` and so is not forwarded.
      def dup
        @lines.dup
      end

      forward_missing_to @lines
    end

    # `awidth_hint`, when given, is this widget's already-resolved absolute width
    # for the current frame — the render path knows it cheaply (the parent has
    # rendered, so `awidth(true)` is an O(1) `lpos` read) and passes it in so the
    # default `awidth` (`get: false`) ancestor-chain walk — which runs here every
    # frame, before the parse cache is even consulted — is skipped. Off-render
    # callers (resize/attach/scroll) omit it and resolve the width as before.
    def process_content(no_tags = false, awidth_hint : Int32? = nil)
      # Content layout (wrapping/alignment) needs the owning screen's
      # dimensions, so there is nothing to do until the widget is attached.
      return false unless screen?

      ::Log.trace { "Parsing widget content: #{@content.inspect}" }

      colwidth = (awidth_hint || awidth) - iwidth
      if @_clines.nil? || @_clines.empty? || @_clines.width != colwidth || @_clines.content_version != @_content_version
        # Single pass over the content instead of four chained `gsub`s (each of
        # which scanned the whole string and built an intermediate copy). The
        # four rules act on disjoint characters — control chars, a stray ESC
        # (not starting an SGR sequence), CR/CRLF, and TAB — so collapsing them
        # into one alternation with a dispatching block is equivalent. `tab` is
        # hoisted so the replacement string is built once, not per match — and
        # only when the content actually contains a tab, since `style.tab_char *
        # style.tab_size` allocates a `String` and the `"\t"` branch is otherwise
        # never reached (the `""` fallback is a constant, no allocation). On the
        # common tab-free reparse the whole `gsub` also returns `@content`
        # unchanged (Crystal's `gsub` returns the receiver when nothing matches),
        # so this branch is then allocation-free.
        tab = @content.includes?('\t') ? style.tab_char * style.tab_size : ""
        content = @content.gsub(/[\x00-\x08\x0b-\x0c\x0e-\x1a\x1c-\x1f\x7f]|\e(?!\[[\d;]*m)|\r\n|\r|\t/) do |m|
          case m
          when "\r\n", "\r" then "\n"
          when "\t"         then tab
          else                   "" # control char or stray ESC
          end
        end

        ::Log.trace { "Internal content is #{content.inspect}" }

        if true # (screen.full_unicode)
          # double-width chars will eat the next char after render. create a
          # blank character after it so it doesn't eat the real next char.
          # TODO
          # content = content.replace(unicode.chars.all, '$1\x03')

          # iTerm2 cannot render combining characters properly.
          if screen.tput.emulator.iterm2?
            # TODO
            # content = content.replace(unicode.chars.combining, "")
          end
        else
          # no double-width: replace them with question-marks.
          # TODO
          # content = content.gsub unicode.chars.all, "??"
          # delete combining characters since they're 0-width anyway.
          # Note: We could drop this, the non-surrogates would get changed to ? by
          # the unicode filter, and surrogates changed to ? by the surrogate
          # regex. however, the user might expect them to be 0-width.
          # Note: Might be better for performance to drop it!
          # TODO
          # content = content.replace(unicode.chars.combining, '')
          # no surrogate pairs: replace them with question-marks.
          # TODO
          # content = content.replace(unicode.chars.surrogate, '?')
          # XXX Deduplicate code here:
          # content = helpers.dropUnicode(content)
        end

        if !no_tags
          content = _parse_tags content
        end
        ::Log.trace { "After _parse_tags: #{content.inspect}" }

        # Reuse the existing `@_clines` object (refill in place) instead of
        # allocating a new one each reparse — `@_clines` is non-nilable (defaults
        # to an empty `CLines`), so it is always a valid reuse target.
        @_clines = _wrap_content(content, colwidth, into: @_clines)
        @_clines.width = colwidth
        @_clines.content = @content
        @_clines.content_version = @_content_version
        @_clines.attr = _parse_attr @_clines
        @_parse_attr_default = sattr(style)
        # Reuse the `CLines`' own (empty) `ci` array — `_wrap_content` never
        # touches it — by clearing and refilling, instead of allocating a fresh
        # replacement every reparse.
        ci = @_clines.ci
        ci.clear
        @_clines.reduce(0) do |total, line|
          ci.push(total)
          total + line.size + 1
        end

        @_pcontent = @_clines.join "\n"
        emit Crysterm::Event::ParsedContent

        return true
      end

      # The carried-over per-line attrs depend only on the (unchanged) content
      # and the style's base attribute, so recompute them only when that base
      # attr actually changed (default fg/bg/flags). On the common frame where
      # nothing changed this skips the O(content) `_parse_attr` scan entirely.
      da = sattr(style)
      if da != @_parse_attr_default
        @_parse_attr_default = da
        @_clines.attr = _parse_attr(@_clines)
      end

      false
    end

    # Convert `{red-fg}foo{/red-fg}` to `\e[31mfoo\e[39m`.
    def _parse_tags(text)
      return text unless @parse_tags
      return text unless text =~ /{\/?[\w\-,;!#]*}/

      # Accumulate into a `String::Builder` rather than `outbuf += ...`: repeated
      # `String` concatenation rebuilds the whole (growing) result on every tag,
      # which is O(n^2) for heavily-tagged content. The cursor is an integer
      # offset (`pos`) advanced through `text` with ANCHORED matches at that
      # offset, instead of re-slicing `text = text[cap[0].size..]` each step —
      # the old reslicing allocated a fresh tail `String` per tag/segment, a
      # second O(n^2). (Anchored matching at an offset is the same technique
      # `_parse_attr` already uses to scan SGR sequences without slicing.) This
      # path is cold — content-change only — but the quadratic blowup made
      # heavily-tagged content disproportionately expensive to (re)parse.
      outbuf = String::Builder.new
      bg = [] of String
      fg = [] of String
      flag = [] of String

      esc = false
      pos = 0
      size = text.size
      anchored = Regex::MatchOptions::ANCHORED

      while pos < size
        if !esc && (cap = /{escape}/.match(text, pos, options: anchored))
          pos += cap[0].size
          esc = true
          next
        end

        if esc && (cap = /([\s\S]+?){\/escape}/.match(text, pos, options: anchored))
          pos += cap[0].size
          outbuf << cap[1]
          esc = false
          next
        end

        if esc
          # raise "Unterminated escape tag."
          outbuf << text[pos..]
          break
        end

        # Matches {normal}{/normal} and all other tags
        if cap = /{(\/?)([\w\-,;!#]*)}/.match(text, pos, options: anchored)
          pos += cap[0].size
          slash = cap[1] == "/"
          # XXX Tags must be specified such as {light-blue-fg}, but are then
          # parsed here with - being ' '. See why? Can we work with - and skip
          # this replacement part?
          param = cap[2].gsub(/-/, ' ')

          if param == "open"
            outbuf << '{'
            next
          elsif param == "close"
            outbuf << '}'
            next
          end

          state = if param.ends_with?(" bg")
                    bg
                  elsif param.ends_with?(" fg")
                    fg
                  else
                    flag
                  end

          if slash
            if param.nil? || param.blank?
              outbuf << (screen.tput._attr("normal") || "")
              bg.clear
              fg.clear
              flag.clear
            else
              attr = screen.tput._attr(param, false)
              if attr.nil?
                outbuf << cap[0]
              else
                # D O:
                # if (param !== state[state.size - 1])
                #   throw new Error('Misnested tags.')
                # }
                state.pop
                outbuf << (state.size > 0 ? (screen.tput._attr(state[-1]) || "") : attr)
              end
            end
          else
            if param.nil?
              outbuf << cap[0]
            else
              attr = screen.tput._attr(param)
              if attr.nil?
                outbuf << cap[0]
              else
                state.push(param)
                outbuf << attr
              end
            end
          end

          next
        end

        if cap = /[\s\S]+?(?={\/?[\w\-,;!#]*})/.match(text, pos, options: anchored)
          pos += cap[0].size
          outbuf << cap[0]
          next
        end

        outbuf << text[pos..]
        break
      end

      outbuf.to_s
    end

    def _parse_attr(lines : CLines)
      default_attr = sattr(style)
      attr = default_attr
      # Reuse the `CLines`' own `attr` array (clear + refill) so a reparse does
      # not allocate a fresh `Array(Int64)` each time; allocated once on first
      # use. The caller assigns the result back to `lines.attr`, which is this
      # same array, so that assignment is a no-op.
      attrs = (lines.attr ||= [] of Int64)
      attrs.clear

      lines.each do |line|
        attrs.push attr

        # `each_char_with_index` walks the codepoints without materializing a
        # `line.chars` array, and the SGR match is anchored in place at `i`
        # instead of slicing `line[i..]` — so a colored line is scanned with no
        # per-line/per-escape `String` allocation. (Matching at THIS escape, not
        # a fixed offset of 1, preserves the leading-SGR fix.)
        line.each_char_with_index do |char, i|
          if char == '\e'
            if c = SGR_REGEX.match(line, i, options: Regex::MatchOptions::ANCHORED)
              attr = screen.attr2code(c[0], attr, default_attr)
            end
          end
        end
      end

      attrs
    end

    # Wraps content based on available widget width.
    #
    # `into`, when given, is an existing `CLines` to refill in place rather than
    # allocating a fresh one — `process_content` passes the widget's own
    # `@_clines`, so steady-state reparsing reuses the same object and its array
    # buffers (see `CLines#reset`). When nil a new `CLines` is built.
    def _wrap_content(content, colwidth, into : CLines? = nil)
      default_state = @align
      wrap = @wrap_content
      margin = 0
      outbuf = into || CLines.new
      # Clear the in-place arrays so a reused `CLines` starts empty (a no-op on a
      # freshly built one). After this, fill the `CLines`' own `rtof`/`ftor`
      # arrays directly via these aliases — no throwaway locals reassigned at the
      # end. (The empty-content branch below returns before these are used and
      # sets its own literals.)
      outbuf.reset
      rtof = outbuf.rtof
      ftor = outbuf.ftor

      if !content || content.empty?
        outbuf.push(content)
        outbuf.rtof = [0]
        outbuf.ftor = [[0]]
        outbuf.fake = [] of String
        outbuf.real = outbuf
        outbuf.max_width = 0
        return outbuf
      end

      lines = content.split "\n"

      margin += 1 if @scrollbar
      margin += 1 if is_a? Widget::TextArea
      colwidth -= margin if colwidth > margin

      lines.each_with_index do |line, no|
        align = default_state
        align_left_too = false

        ftor.push [] of Int32

        # Handle alignment tags.
        if @parse_tags
          if cap = line.match /^{(left|center|right)}/
            align_left_too = true
            line = line[cap[0].size..]
            align = default_state = case cap[1]
                                    when "center"
                                      Tput::AlignFlag::Center
                                    when "left"
                                      Tput::AlignFlag::Left
                                    else
                                      Tput::AlignFlag::Right
                                    end
          end
          if cap = line.match /{\/(left|center|right)}$/
            line = line[0...(line.size - cap[0].size)]
            # Reset default_state to whatever alignment the widget has by default.
            default_state = @align
          end
        end

        # If the string could be too long, check it in more detail and wrap it if needed.
        # NOTE Done with loop+break due to https://github.com/crystal-lang/crystal/issues/1277
        loop_ret = loop do
          break unless str_width(line) > colwidth

          # Character index at which to cut so the kept prefix fits `colwidth`
          # columns. SGR sequences consume no width; under `full_unicode?` widths
          # are grapheme / East-Asian and clusters are never split.
          i = wrap_cut_index(line, colwidth)

          # If we're not wrapping the text, keep the columns that fit plus any
          # remaining control sequences, and cut the rest off.
          unless @wrap_content
            rest = line[i..].scan(/\e\[[^m]*m/).join # remaining SGR sequences
            outbuf.push _align(line[0...i] + rest, colwidth, align, align_left_too)
            ftor[no].push(outbuf.size - 1)
            rtof.push(no)
            break :main
          end

          # Try to break on a space within the last few columns (word wrap).
          if i != line.size
            j = i
            # TODO how can the condition and subsequent IF ever match
            # with the line[j] thing?
            while (j > i - 10) && (j > 0) && (j -= 1) && (line[j] != ' ')
              if line[j] == ' '
                i = j + 1
              end
            end
          end

          part = line[0...i]
          line = line[i..]

          outbuf.push _align(part, colwidth, align, align_left_too)
          ftor[no].push(outbuf.size - 1)
          rtof.push(no)

          # Make sure we didn't wrap the line at the very end, otherwise
          # we'd get an extra empty line after a newline.
          if line == ""
            break :main
          end

          # If only an escape code got cut off, add it to `part`.
          if line.matches? /^(?:\e[\[\d;]*m)+$/ # SGR
            outbuf[outbuf.size - 1] += line
            break :main
          end
        end

        if loop_ret == :main
          no += 1
          next
        end

        outbuf.push(_align(line, colwidth, align, align_left_too))
        ftor[no].push(outbuf.size - 1)
        rtof.push(no)

        no += 1
      end

      # `rtof`/`ftor` already alias `outbuf`'s own arrays (filled in place above),
      # so no reassignment is needed here.
      outbuf.fake = lines
      outbuf.real = outbuf

      # Note that this is intended to save the length of the longest line to
      # outbuf.max_width. In the case that the text was aligned, the alignment
      # has padded it with spaces, effectively lengthening it. So, in that case
      # the max_width value won't be actual max. length of longest line, but it
      # will be the full width of the surrounding box, to which it was aligned.
      outbuf.max_width = outbuf.reduce(0) do |current, line|
        Math.max str_width(line), current
      end

      outbuf
    end

    # Aligns content
    def _align(line, width, align = Tput::AlignFlag::None, align_left_too = false)
      return line if align.none?

      # Only run the SGR-stripping `gsub` (which allocates a fresh `String`) when
      # the line actually contains an escape; the vast majority of aligned lines
      # carry no color, so a cheap `includes?` byte scan lets them reuse `line`
      # with no allocation. When there is no ESC, `cline == line` and everything
      # below (width, splits) behaves identically.
      cline = line.includes?('\e') ? line.gsub(SGR_REGEX, "") : line
      # `cline` is already SGR-stripped (or had none), so measure it directly.
      # `str_width line` would strip the SGR sequences a second time; `str_width
      # cline` skips the regex (no ESC present) and yields the identical width.
      len = str_width cline

      # XXX In blessed's code (and here) it was done only with this commented
      # line below. But after/around the May 28 2021 changes, this stopped
      # centering texts. Upon investigation, it was found this is because a
      # Layout sets all its children to #resizable=true (shrink=true in blessed),
      # so the free width (s) results being 0 here. But why this code worked
      # up to May is unexplained, since no obvious changes were done in this
      # code. Or, cn this be a bug we unintentionally fixed?
      # s = @resizable ? 0 : width - len
      # NOTE: `width` is an Int, so the old `!width` was always false (only
      # `nil`/`false` are falsy in Crystal), making the resizable branch dead.
      # The intent is to skip alignment padding for a resizable widget that has
      # no usable width yet, i.e. `width == 0`.
      s = (@resizable && width == 0) ? 0 : width - len

      return line if len == 0
      return line if s < 0

      if (align & Tput::AlignFlag::HCenter) != Tput::AlignFlag::None
        s = " " * (s//2)
        return s + line + s
      elsif align.right?
        s = " " * s
        return s + line
      elsif align_left_too && align.left?
        # Technically, left align is visually the same as no align at all.
        # But when text is aligned to center or right, all the available empty space is padded
        # with spaces (around the text in center align, and in front of text in right align).
        # So, because of this padding with spaces, which affects the size of the widget, we
        # want to pad {left} align for uniformity as well.
        #
        # But, because aligning left affects almost everything in undesired ways (a lot
        # more chars are present, and cursor in text widgets is wrong), we do not want to do
        # this when Widget's `align = AlignFlag::Left`. We only want to do it when there is
        # "{left}" in content, and parse_tags is true.
        #
        # This should ensure that {left|center|right} behave 100% identical re. the effect
        # it has on row width. To see the old behavior without this, comment this elseif,
        # run test/widget-list.cr, and observe the look of the first element in the list
        # vs. the other elements when they are selected.
        s = " " * s
        return line + s
      elsif @parse_tags && (line.includes?('{') || line.includes?('}'))
        # XXX This is basically Tput::AlignFlag::Spread, but not sure
        # how to put that as a flag yet. Maybe this (or another)
        # widget flag could mean to spread words to fill up the whole
        # line, increasing spaces between them?
        parts = line.split /\{|\}/

        cparts = cline.split /\{|\}/
        if cparts[0]? && cparts[2]? # Don't trip on just single { or }
          s = Math.max(width - str_width(cparts[0]) - str_width(cparts[2]), 0)
          s = " " * s
          return "#{parts[0]}#{s}#{parts[2]}"
        else
          # Nothing; will default to returning `line` below.
        end
      end

      line
    end

    # Rebuilds the widget's content from the in-place-mutated `@_clines.fake`
    # lines (re-joining them and reparsing). The `no_clear` flag is set so the
    # existing `@_clines` machinery is refreshed rather than wiped. Used by the
    # line-level editors (`insert_line`/`delete_line`/`set_line`) after they
    # splice `fake`.
    private def rebuild_content_from_fake
      set_content(@_clines.fake.join("\n"), true)
    end

    def insert_line(i = nil, line = "")
      if line.is_a? String
        line = line.split("\n")
      end

      if i.nil?
        i = @_clines.ftor.size
      end

      i = Math.max(i, 0)

      while @_clines.fake.size < i
        @_clines.fake.push("")
        @_clines.ftor.push([@_clines.push("").size - 1])
        # Discarded read kept only for parity with the port; use the safe `[]?`
        # so it cannot raise `IndexError` when `rtof` is shorter than `fake`.
        @_clines.rtof[@_clines.fake.size - 1]?
      end

      # NOTE: Could possibly compare the first and last ftor line numbers to see
      # if they're the same, or if they fit in the visible region entirely.
      start = @_clines.size
      # diff
      # real

      if i >= @_clines.ftor.size
        real = @_clines.ftor[@_clines.ftor.size - 1]
        real = real[-1] + 1
      else
        real = @_clines.ftor[i][0]
      end

      line.size.times do |j|
        @_clines.fake.insert(i + j, line[j])
      end

      rebuild_content_from_fake

      diff = @_clines.size - start

      if diff > 0
        pos = _get_coords
        if !pos || pos == 0
          return
        end

        height = pos.yl - pos.yi - iheight
        base = @child_base
        visible = real >= base && real - base < height

        if pos && visible && screen.clean_sides(self)
          screen.insert_line(diff,
            pos.yi + itop + real - base,
            pos.yi,
            pos.yl - ibottom - 1)
        end
      end
    end

    def delete_line(i = nil, n = 1)
      if i.nil?
        i = @_clines.ftor.size - 1
      end

      i = i.clamp(0, @_clines.ftor.size - 1)

      # NOTE: Could possibly compare the first and last ftor line numbers to see
      # if they're the same, or if they fit in the visible region entirely.
      start = @_clines.size
      # diff
      real = @_clines.ftor[i][0]

      n.times { @_clines.fake.delete_at i }

      rebuild_content_from_fake

      diff = start - @_clines.size

      # XXX clear_last_rendered_position() without diff statement?
      height = 0

      if diff > 0
        pos = _get_coords
        if !pos || pos == 0
          return
        end

        height = pos.yl - pos.yi - iheight

        base = @child_base
        visible = real >= base && real - base < height

        if pos && visible && screen.clean_sides(self)
          screen.delete_line(diff,
            pos.yi + itop + real - base,
            pos.yi,
            pos.yl - ibottom - 1)
        end
      end

      # When content shrank this used to erase the leftover footprint via
      # `clear_last_rendered_position`; the whole-buffer clear in `Screen#_render`
      # now takes care of that, so the explicit clear is no longer needed.
    end

    # Maps a real (wrapped) line index to its fake (logical) line index via
    # `@_clines.rtof`, guarding against out-of-range access. `rtof` has one
    # entry per wrapped line, so indices such as `@child_base` are normally in
    # range, but for empty/short content (e.g. before content is wrapped) a raw
    # `rtof[i]` would raise `IndexError`. Returns 0 when `rtof` is empty and
    # clamps otherwise.
    private def rtof_index(i)
      rtof = @_clines.rtof
      return 0 if rtof.empty?
      rtof[i.clamp(0, rtof.size - 1)]
    end

    def insert_top(line)
      fake = rtof_index(@child_base)
      insert_line(fake, line)
    end

    def insert_bottom(line)
      h = (@child_base) + aheight - iheight
      i = Math.min(h, @_clines.size)
      fake = rtof_index(i - 1) + 1

      insert_line(fake, line)
    end

    def delete_top(n = 1)
      fake = rtof_index(@child_base)
      delete_line(fake, n)
    end

    def delete_bottom(n)
      h = (@child_base) + aheight - 1 - iheight
      i = Math.min(h, @_clines.size - 1)
      fake = rtof_index(i)

      n = 1 if !n || n == 0

      delete_line(fake - (n - 1), n)
    end

    def set_line(i, line)
      i = Math.max(i, 0)
      # Pad up to AND including index `i` (`<=`, not `<`). Blessed relies on JS
      # auto-extending arrays so `fake[i] = line` can create the slot; in Crystal
      # `fake[i] = line` raises when `i == fake.size` (e.g. `set_line(0, …)` on an
      # empty `fake`, as `push_line` does for empty content), so the slot must
      # exist first.
      while @_clines.fake.size <= i
        @_clines.fake.push("")
      end
      @_clines.fake[i] = line
      rebuild_content_from_fake
    end

    def set_baseline(i, line)
      fake = rtof_index(@child_base)
      set_line(fake + i, line)
    end

    def get_line(i)
      i = i.clamp(0, @_clines.fake.size - 1)
      @_clines.fake[i]
    end

    def get_baseline(i)
      fake = rtof_index(@child_base)
      get_line(fake + i)
    end

    def clear_line(i)
      i = Math.min(i, @_clines.fake.size - 1)
      set_line(i, "")
    end

    def clear_base_line(i)
      fake = rtof_index(@child_base)
      clear_line(fake + i)
    end

    def unshift_line(line)
      insert_line(0, line)
    end

    def shift_line(n)
      delete_line(0, n)
    end

    def push_line(line)
      # `@content` is a non-nilable String, so the old `!@content` was always
      # false (an empty String is truthy in Crystal) and this never set line 0.
      if @content.empty?
        return set_line(0, line)
      end
      insert_line(@_clines.fake.size, line)
    end

    def pop_line(n)
      delete_line(@_clines.fake.size - 1, n)
    end

    def get_lines
      @_clines.fake.dup
    end

    def get_screen_lines
      @_clines.dup
    end

    # Whether grapheme / column-width-aware layout is in effect for this widget;
    # delegates to the owning screen's effective gate (`Screen#full_unicode?` =
    # option AND terminal capability). False when unattached.
    def full_unicode?
      screen?.try(&.full_unicode?) || false
    end

    # Width, in terminal COLUMNS, of `text`'s visible content. SGR sequences are
    # stripped (they occupy no columns); whitespace is preserved. With
    # `#full_unicode?` this is grapheme / East-Asian width (`Unicode`), otherwise
    # the codepoint count (legacy behavior).
    #
    # This is the single width hook layout should use; previously most call sites
    # inlined `.size`, which miscounts wide / combining characters.
    def str_width(text)
      # Most strings have no SGR sequences; skip the regex (and the new String
      # it builds) unless an ESC is actually present. The `includes?` scan is a
      # cheap allocation-free byte check.
      text = text.gsub SGR_REGEX, "" if text.includes? '\e'
      full_unicode? ? Unicode.display_width(text) : text.size
    end

    # Longest *suffix* of `text` whose display width fits within `cols` columns,
    # measured by grapheme cluster (wide characters count as 2; clusters are
    # never split). Used by single-line inputs to show the tail of an over-long
    # value under `#full_unicode?`.
    def tail_within(text : String, cols : Int) : String
      return "" if cols <= 0
      return text if str_width(text) <= cols

      kept = [] of String
      width = 0
      text.each_grapheme.to_a.reverse_each do |g|
        gw = Unicode.width g
        break if width + gw > cols
        width += gw
        kept << g.to_s
      end
      kept.reverse!
      kept.join
    end

    # Returns `text` with its last **grapheme cluster** removed (e.g. a base +
    # combining mark, or a wide emoji, comes off as one unit). Used for
    # grapheme-aware backspace in text inputs. Empty in, empty out.
    def chop_grapheme(text : String) : String
      return text if text.empty?
      text.each_grapheme.to_a[0...-1].join
    end

    # Whether *base* begins a multi-codepoint grapheme cluster, given its
    # successor *nxt* — i.e. whether `#extend_grapheme` would assemble anything
    # beyond `base` alone. This is the cheap pre-check that lets the renderer skip
    # the (String-allocating) cluster assembly for the lone codepoint that the
    # overwhelming majority of cells are. It exactly mirrors `#extend_grapheme`'s
    # own start conditions, so `needs_cluster? == false` ⟺ the cluster is just
    # `base`.
    def needs_cluster?(base : Char, nxt : Char?) : Bool
      return true if base.mark? # a leading combining mark (zero-width; merges back)
      bp = base.ord
      return true if 0x1F1E6 <= bp <= 0x1F1FF # regional indicator (flag pair)
      return false unless nxt
      np = nxt.ord
      # A following combining mark, ZWJ, variation selector, or skin-tone modifier
      # extends the cluster.
      nxt.mark? || np == 0x200D || (0xFE00 <= np <= 0xFE0F) || (0x1F3FB <= np <= 0x1F3FF)
    end

    # Assembles the grapheme cluster that begins with `base` (the codepoint at
    # `content[ci - 1]`) by consuming any following *extending* codepoints from
    # `content` starting at `ci`: combining marks, ZWJ (and the codepoint it
    # joins), variation selectors, emoji skin-tone modifiers, and — for a flag —
    # a second regional indicator. Returns `{cluster, new_ci}`.
    #
    # This is a pragmatic subset of UAX-#29 that covers the cases that actually
    # occur in terminal text; `content` is anything indexable by codepoint
    # (`#[]?` returning `Char?`).
    def extend_grapheme(content, ci : Int32, base : Char) : Tuple(String, Int32)
      g = String::Builder.new
      g << base

      # A flag is a pair of regional indicators.
      if 0x1F1E6 <= base.ord <= 0x1F1FF
        if (c = content[ci]?) && (0x1F1E6 <= c.ord <= 0x1F1FF)
          g << c
          ci += 1
        end
        return {g.to_s, ci}
      end

      while c = content[ci]?
        cp = c.ord
        if c.mark? || cp == 0x200D || (0xFE00 <= cp <= 0xFE0F) || (0x1F3FB <= cp <= 0x1F3FF)
          g << c
          ci += 1
          # A ZWJ also pulls in the codepoint it joins (e.g. the next emoji).
          if cp == 0x200D && (c2 = content[ci]?)
            g << c2
            ci += 1
          end
        else
          break
        end
      end

      {g.to_s, ci}
    end

    # Character index in `line` (which may contain inline SGR) at which to cut so
    # the kept prefix fits within `colwidth` columns. SGR sequences (`\e[…m`)
    # consume no columns. Under `#full_unicode?` widths are grapheme /
    # East-Asian and grapheme clusters are never split; otherwise it is one
    # column per codepoint (legacy). Returns `line.size` when the whole line
    # fits, and always makes progress — a single grapheme wider than `colwidth`
    # is kept whole (overflowing) rather than looping forever.
    def wrap_cut_index(line : String, colwidth : Int) : Int32
      full = full_unicode?
      total = 0
      i = 0
      n = line.size
      while i < n
        if line[i] == '\e'
          i += 1
          while i < n && line[i] != 'm'
            i += 1
          end
          i += 1 if i < n # consume the terminating 'm'
          next
        end

        # Contiguous run of visible text up to the next SGR (or end of line).
        run_end = i
        while run_end < n && line[run_end] != '\e'
          run_end += 1
        end

        if full
          pos = i
          line[i...run_end].each_grapheme do |g|
            gs = g.to_s
            w = Unicode.width gs
            # Cut before this cluster once we already have content placed.
            return pos if total + w > colwidth && total > 0
            total += w
            pos += gs.size
          end
          i = run_end
        else
          (i...run_end).each do |k|
            total += 1
            return k + 1 if total == colwidth
          end
          i = run_end
        end
      end
      i
    end
  end

  # A wrapper around indexable objects that returns nil on [-idx] rather than
  # [idx] counted from the back.
  #
  # It is needed in drawing routines where index is often offset by a certain
  # value and expected that all indexes < 0 will return nil.
  struct StringIndex
    getter object : String
    # Non-ASCII path: codepoints materialized once. nil for ASCII content.
    @chars : Array(Char)?
    # ASCII fast path: a zero-copy byte view of `@object`. For an ASCII string a
    # byte *is* its codepoint, so indexing the bytes directly avoids
    # `String#[]?(Int)` — which recomputes `size` and decodes a char on every
    # call. Per cell that call dominated the render CPU profile; a byte view is
    # allocation-free (a slice over the string's buffer) and indexes in one
    # bounds-checked fetch. nil for non-ASCII content (which uses `@chars`).
    @bytes : Bytes?
    # Codepoint count, cached so `#size` and the per-cell bounds check below are
    # field reads, not `String#size` calls.
    @size : Int32

    def initialize(@object : String)
      if @object.ascii_only?
        @chars = nil
        @bytes = @object.to_slice
        @size = @object.bytesize # == codepoint count for ASCII
      else
        # Materialize the chars once (O(n)) so per-cell indexing is O(1) instead
        # of `String#[](Int)`'s O(n) codepoint walk (which made drawing a line of
        # Unicode content O(n²)).
        chars = @object.chars
        @chars = chars
        @bytes = nil
        @size = chars.size
      end
    end

    # Whether this index was built from `s` (the *same* `String` object). The
    # render loop builds one `StringIndex` per widget per frame from
    # `@_pcontent`, which only changes when content is reparsed; this lets the
    # caller reuse a cached index across frames instead of rebuilding the
    # `chars` array (and re-running the `ascii_only?` scan) every frame.
    def built_from?(s : String) : Bool
      @object.same? s
    end

    # Per-cell hot path: a negative or out-of-range index yields nil; otherwise
    # an ASCII byte fetch (the common case) or an `unsafe_fetch` into the cached
    # `chars` array — neither calls `String#[]?`/`String#size`.
    @[AlwaysInline]
    def []?(i : Int) : Char?
      return nil if i < 0 || i >= @size
      if bytes = @bytes
        bytes.unsafe_fetch(i).unsafe_chr
      else
        @chars.not_nil!.unsafe_fetch(i)
      end
    end

    def [](i : Int) : Char?
      return nil if i < 0
      raise IndexError.new if i >= @size
      if bytes = @bytes
        bytes.unsafe_fetch(i).unsafe_chr
      else
        @chars.not_nil!.unsafe_fetch(i)
      end
    end

    def [](range : Range)
      @object[range]
    end

    def size
      @size
    end
  end
end
