module Crysterm
  class Widget
    # Single-pass content sanitization shared by `process_content` (whole
    # content) and `append_content` (appended segment only): strips control
    # characters and a stray ESC (not starting an SGR sequence), normalizes
    # CR/CRLF to LF, and expands TAB to `tab_char * tab_size`. Allocation-free on
    # tab-free, match-free input.
    private def clean_content_chars(text : String) : String
      tab = text.includes?('\t') ? style.tab_char * style.tab_size : ""
      text.gsub(/[\x00-\x08\x0b-\x0c\x0e-\x1a\x1c-\x1f\x7f]|\e(?!\[[\d;]*m)|\r\n|\r|\t/) do |m|
        case m
        when "\r\n", "\r" then "\n"
        when "\t"         then tab
        else                   "" # control char or stray ESC
        end
      end
    end

    # Memo key of the cache-hit tail of `process_content` below: the resolved
    # `#style` object, its `Style#attr_revision`, and the `@_parse_attr_default`
    # value derived from it, at stamp time. All three halves are load-bearing:
    # identity alone is unsafe (an animation mutates the style in place —
    # bumping the revision — without swapping the object), revision alone is
    # unsafe (the cascade swaps in a different `Style` whose counter is
    # unrelated), and the stamped default guards against `@_parse_attr_default`
    # having been rewritten from *another* style meanwhile (a reparse under a
    # substituted state style, then a swap back to this same object at an
    # unchanged revision, must still refresh). Holding the object reference
    # rather than an `object_id` also keeps the style alive, so the `same?`
    # test can't false-hit on a recycled address.
    @_parse_attr_style : Style?
    @_parse_attr_style_revision : Int64 = 0_i64
    @_parse_attr_style_default : Int64? = nil

    # `awidth_hint`, when given, is this widget's already-resolved absolute width
    # for the current frame — the render path knows it cheaply (`awidth(true)` is
    # an O(1) `lpos` read once the parent has rendered) and passes it in to skip
    # the default `awidth` ancestor-chain walk. Off-render callers (resize/
    # attach/scroll) omit it and resolve the width themselves.
    def process_content(no_tags = false, awidth_hint : Int32? = nil)
      # Content layout needs the owning window's dimensions, so nothing to do
      # until the widget is attached.
      return false unless window?

      ::Log.trace { "Parsing widget content: #{@content.inspect}" }

      colwidth = (awidth_hint || awidth) - ihorizontal
      # `@_clines.margin` is part of the wrap cache key: an `AsNeeded` scroll bar's
      # presence (and thus `content_margin_x`) can flip from a height-only change
      # (resize, `widget.height=`) that leaves the other cache-key fields
      # unchanged, and the stale-margin lines would let the bar overpaint the last
      # content column. The convergence loop below leaves
      # `@_clines.margin == content_margin_x`, so this doesn't re-fire in steady state.
      if @_clines.nil? || @_clines.empty? || @_clines.width != colwidth || @_clines.content_version != @_content_version || @_clines.base_x != @child_base_x || @_clines.margin != content_margin_x || @_clines.tab_size != style.tab_size || @_clines.tab_char != style.tab_char || @_clines.fill_char != style.fill_char
        # A reparse reads raw `@content`, so fold deferred appends first (the
        # cache-hit path below never reaches here).
        fold_content_tail
        content = clean_content_chars @content

        ::Log.trace { "Internal content is #{content.inspect}" }

        # No content-level Unicode munging here: wide-char layout, grapheme
        # clusters, and combining marks are handled at the cell level in the
        # renderer (keyed off `window.full_unicode?`).

        # Parse tags only when not disabled and content actually has tags; skips
        # `_parse_tags`'s regex scan for plain text. `@_content_no_tags` records
        # the mode content was set with (e.g. via `#set_text`), so a later
        # cache-miss reparse (width change, resize, scroll, attach — all calling
        # with the default `no_tags = false`) keeps tags literal.
        if !no_tags && !@_content_no_tags && @_content_has_tags
          content = _parse_tags content
          # This parse consumed the whole raw content, so its end state IS the
          # boundary state a future append would splice at.
          @_content_open_tags_at_end = @_parse_tags_left_open
        else
          # Tags stay literal (none present, or `no_tags` mode), so no tag state
          # can be open at the end.
          @_content_open_tags_at_end = false
        end
        ::Log.trace { "After _parse_tags: #{content.inspect}" }

        # Wrap, then converge the scroll-bar reservation: an `AsNeeded` bar's
        # presence depends on the wrapped line count, known only after wrapping,
        # yet the wrap width depends on the bar reserving its column. Pass 1 must
        # seed from the margin an *empty* widget would reserve, NOT the previous
        # wrap's line count — seeding from history latches bistable content into
        # the with-bar layout forever. Monotonic: reserving a column only narrows
        # width and adds lines, so the bar can't then disappear — two passes always
        # suffice, and the no-bar fixed point wins whenever it exists.
        margin = content_margin_x_empty
        2.times do
          @_clines = _wrap_content(content, colwidth, into: @_clines, margin: margin)
          # Break test keys off line count, which `_wrap_content` already set;
          # cache-key fields below don't affect it, so set them once after.
          needed = content_margin_x
          break if needed == margin
          margin = needed
        end
        @_clines.width = colwidth
        @_clines.base_x = @child_base_x
        @_clines.content = @content
        @_clines.content_version = @_content_version
        @_clines.tab_size = style.tab_size
        @_clines.tab_char = style.tab_char
        @_clines.fill_char = style.fill_char
        # `_parse_attr` also records `style_to_attr(style)` in `@_parse_attr_default`, so
        # no separate recompute is needed here.
        @_clines.attr = _parse_attr @_clines
        # Reuse the `CLines`' own `ci` array (clear + refill) instead of
        # allocating a fresh replacement every reparse.
        ci = @_clines.ci
        ci.clear
        @_clines.reduce(0) do |total, line|
          ci.push(total)
          total + line.size + 1
        end

        @_pcontent = clines_joined
        emit Crysterm::Event::ContentParsed

        return true
      end

      # Refresh the cached base attribute only when it actually changed.
      # `@_parse_attr_default` MUST stay current regardless of content shape: it
      # is read unconditionally as the widget's fill/background attr, so freezing
      # it freezes the background of any widget that only changes `style.bg`
      # (e.g. an empty single-line `Effect::CopperBar` stops animating).
      #
      # The `style_to_attr` recompute itself is gated on the
      # `{identity, Style#attr_revision, stamped default}` memo (see the ivar
      # triple above): every setter of a field `style_to_attr` reads bumps the
      # revision, so the common steady-state frame (same object, no
      # attr-relevant mutation) skips the 7-predicate flag walk + pack
      # entirely, while an in-place `style.bg = color` advances the revision
      # and still lands in the refresh below. The reparse path above doesn't
      # stamp this key (`_parse_attr` keeps `@_parse_attr_default` current
      # itself), so the first cache-hit frame after a reparse recomputes once
      # and restamps — correct, just not free.
      st = style
      unless st.same?(@_parse_attr_style) &&
             @_parse_attr_style_revision == st.attr_revision &&
             @_parse_attr_style_default == @_parse_attr_default
        da = style_to_attr(st)
        @_parse_attr_style = st
        @_parse_attr_style_revision = st.attr_revision
        @_parse_attr_style_default = da
        if da != @_parse_attr_default
          @_parse_attr_default = da
          # Recompute whenever a packed attr array already exists — never gate this
          # on line count. A populated-but-stale array is latched forever (`da` now
          # equals `@_parse_attr_default`, so the refresh never fires again) and
          # appended/scrolled lines paint with the old default attr permanently.
          # `nil` means no reader can see it, so nothing to refresh.
          @_clines.attr = _parse_attr(@_clines) unless @_clines.attr.nil?
        end
      end

      false
    end

    # Appends one finished wrapped (real) line and records the fake↔real
    # mapping: `line` becomes a new real row of `outbuf`, fake line `no` gains
    # that real index in `ftor`, and `rtof` gains `no`.
    #
    # `width`, when given, is the aligned line's already-known display width,
    # sparing a re-`str_width` (and thus a re-strip of the line's SGR).
    private def push_real_line(outbuf : CLines, ftor, rtof, no : Int32, line : String, width : Int32? = nil) : Nil
      outbuf.push line
      ftor[no].push(outbuf.size - 1)
      rtof.push(no)
      # Accumulate the widest real line as lines are emitted, rather than in a
      # second pass re-measuring every one. Safe: the one later in-place mutation
      # of a pushed line appends only zero-width SGR.
      w = width || str_width(line)
      outbuf.max_width = w if w > outbuf.max_width
    end

    # Wraps content based on available widget width.
    #
    # `into`, when given, is an existing `CLines` to refill in place rather than
    # allocating a fresh one, so steady-state reparsing reuses the same object and
    # its array buffers. When nil a new `CLines` is built.
    def _wrap_content(content, colwidth, into : CLines? = nil, margin : Int32? = nil)
      default_state = @align
      # The right-edge reservation this wrap subtracts. When not passed in it must
      # be captured HERE, before `outbuf.reset` clears `@_clines`: `content_margin_x`
      # reads `@_clines.size` to size an `AsNeeded` bar and post-reset would see
      # zero lines mid-wrap.
      margin ||= content_margin_x
      outbuf = into || CLines.new
      # Record the reservation this wrap is built against, so a caller can tell
      # when an `AsNeeded` bar's presence (only known post-wrap) flips it and a
      # re-wrap is needed.
      outbuf.margin = margin
      # Clear in-place arrays so a reused `CLines` starts empty (no-op when freshly
      # built). The `rtof`/`ftor` aliases below fill the `CLines`' own arrays
      # directly. (The empty-content branch returns before these are used.)
      outbuf.reset
      outbuf.full_width = 0
      # `reset` doesn't touch scalar `max_width`; zero it so `push_real_line` can
      # accumulate the widest real line as they're emitted.
      outbuf.max_width = 0
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

      # Reuse the `fake` array for common single-line content (label, list item,
      # panel title): refill in place instead of letting `String#split` allocate a
      # fresh `Array(String)` every reparse. Multi-line content still splits, since
      # its substrings must be allocated anyway.
      if content.includes?('\n')
        lines = content.split('\n')
      else
        lines = outbuf.fake
        lines.clear
        lines << content
      end

      # Subtract the right-edge reservation so content wraps clear of the scroll
      # bar (and any per-widget reservation, e.g. a caret column).
      colwidth -= margin if colwidth > margin

      lines.each_with_index do |line, no|
        align = default_state
        align_left_too = false

        ftor.push outbuf.take_ftor_row

        # Handle alignment tags. The opener may be preceded — and the closer
        # followed — by inline SGR, which happens when an alignment tag nests
        # inside an attribute tag: `{bold}{center}Hi{/center}{/bold}` becomes
        # `\e[1m{center}Hi{/center}\e[22m` after `_parse_tags`. So the match must
        # allow surrounding SGR (and re-prepend/-append it, consuming only the
        # alignment tag); anchoring at the absolute string edge instead silently
        # drops the alignment and leaks the literal tag into output.
        if @parse_tags && !@_content_no_tags && line.includes?('{')
          if cap = line.match /^((?:\e\[[\d;]*m)*){(left|center|right)}/
            align_left_too = true
            # Drop the tag, keep any leading SGR that preceded it.
            line = cap[1] + line[cap[0].size..]
            align = default_state = case cap[2]
                                    when "center"
                                      Tput::AlignFlag::Center
                                    when "left"
                                      Tput::AlignFlag::Left
                                    else
                                      Tput::AlignFlag::Right
                                    end
          end
          if cap = line.match /{\/(left|center|right)}((?:\e\[[\d;]*m)*)$/
            # Drop the closing tag, keep any trailing SGR that followed it.
            line = line[0...(line.size - cap[0].size)] + cap[2]
            # Reset default_state to whatever alignment the widget has by default.
            default_state = @align
          end
        end

        # Without wrapping, the line is one full row: record its true width for
        # the horizontal scroll range, then slice to the visible column window
        # `[child_base_x, child_base_x + colwidth)`. At `child_base_x == 0` this
        # is plain "keep what fits, cut the rest" truncation.
        unless @wrap_content
          outbuf.full_width = Math.max(outbuf.full_width, str_width(line))
          # Take the aligned width `aligned_with_width` already computed rather
          # than re-measuring the padded result in `push_real_line`.
          text, w = aligned_with_width(_hslice(line, @child_base_x, colwidth), colwidth, align, align_left_too)
          push_real_line outbuf, ftor, rtof, no, text, w
          next
        end

        # If the string could be too long, check it in more detail and wrap it if needed.
        # NOTE Done with loop+break due to https://github.com/crystal-lang/crystal/issues/1277
        #
        # Track the remaining line's visible width incrementally rather than
        # re-measuring the whole tail every iteration (O(L²) for one long line).
        # Valid because each cut lands on a grapheme/codepoint boundary and never
        # inside an SGR run, so width is additive across the split.
        remaining_width = str_width(line)
        loop_ret = loop do
          break unless remaining_width > colwidth

          # Character index at which to cut so the kept prefix fits `colwidth`
          # columns. SGR consumes no width; under `full_unicode?` widths are
          # grapheme/East-Asian and clusters are never split.
          i = wrap_cut_index(line, colwidth)

          # Word wrap: back up from the column-fit cut `i` to the most recent
          # space within the previous ~10 chars and cut just after it, so a word
          # isn't split mid-way. Falls back to character-wrap `i` if no space
          # found. Mirrors blessed's `while (j > i-10 && j > 0)` scan.
          #
          # The scan works on raw codepoints, which include inline SGR bytes
          # (`\e[…m`), so escape runs must be skipped: their bytes must neither
          # consume the ~10-char lookback budget nor let the cut land inside a
          # sequence. Meeting a run's terminating `m` walking backwards jumps `j`
          # back to the opening `\e`.
          if i != line.size
            j = i
            while (j > i - 10) && (j > 0)
              j -= 1
              if line[j] == 'm' && (esc = SGR.run_start(line, j))
                # Land `j` on the `\e` so the next `j -= 1` steps past the run.
                j = esc
                next
              end
              if line[j] == ' '
                i = j + 1
                break
              end
            end
          end

          part = line[0...i]
          line = line[i..]
          # `part`'s width is bounded by ~`colwidth`, so this measures O(colwidth)
          # rather than the O(remaining) a `str_width(line)` gate would.
          remaining_width -= str_width(part)

          part_text, part_w = aligned_with_width(part, colwidth, align, align_left_too)
          push_real_line outbuf, ftor, rtof, no, part_text, part_w

          # Make sure we didn't wrap the line at the very end, otherwise
          # we'd get an extra empty line after a newline.
          if line == ""
            break :main
          end

          # If only an escape code got cut off, add it to `part`.
          if line.matches? /^(?:\e\[[\d;]*m)+$/ # SGR
            outbuf[outbuf.size - 1] += line
            break :main
          end
        end

        # `each_with_index` rebinds `no` each iteration, so mutating it here is
        # dead — `next`/falling through both advance to the next fake line.
        next if loop_ret == :main

        tail_text, tail_w = aligned_with_width(line, colwidth, align, align_left_too)
        push_real_line outbuf, ftor, rtof, no, tail_text, tail_w
      end

      # `rtof`/`ftor` already alias `outbuf`'s own arrays (filled in place above).
      outbuf.fake = lines
      outbuf.real = outbuf

      # NOTE `outbuf.max_width` is the widest real line *including* alignment
      # padding, so for aligned text it reflects the surrounding box's width
      # rather than the actual longest line.

      outbuf
    end

    # Aligns content, returning just the aligned string. `#aligned_with_width`
    # additionally hands back the result's display width, sparing a re-measure.
    def _align(line, width, align = Tput::AlignFlag::None, align_left_too = false)
      aligned_with_width(line, width, align, align_left_too)[0]
    end

    # Aligns `line` and returns `{result, width}` where `width` is the result's
    # display columns when cheaply known here, else `nil` — the caller then falls
    # back to `str_width`. Sparing that re-measure avoids a duplicate SGR-strip on
    # every aligned line carrying color.
    private def aligned_with_width(line, width, align = Tput::AlignFlag::None, align_left_too = false) : Tuple(String, Int32?)
      # Right-align separator `{|}` (Blessed): text after it is pushed to the
      # right edge. It distributes content within the line independent of the
      # line's own alignment, so it MUST be handled before the align-direction
      # early-returns below — otherwise it never fires for default Left alignment.
      if @parse_tags && !@_content_no_tags && line.includes?("{|}")
        cl = line.includes?('\e') ? line.gsub(SGR_REGEX, "") : line
        if res = split_right_align(line, cl, width)
          # Result width isn't cheaply `width` here (a too-wide split leaves the
          # pad at 0), so leave it unknown and let the caller measure.
          return {res, nil}
        end
      end

      return {line, nil} if align.none?

      # Plain left alignment pads nothing — only HCenter/Right (or a forced
      # `{left}` via `align_left_too`) add spaces. Bailing before measuring skips
      # a `str_width` on every line of the common default-`Left` case.
      if !align_left_too && (align & (Tput::AlignFlag::HCenter | Tput::AlignFlag::Right)).none?
        return {line, nil}
      end

      # Only run the SGR-stripping `gsub` when an escape is actually present, so
      # the uncolored majority reuses `line` with no allocation.
      cline = line.includes?('\e') ? line.gsub(SGR_REGEX, "") : line
      # `cline` is already SGR-stripped, so this skips the regex scan
      # `str_width line` would repeat.
      len = str_width cline

      # A `Layout` sets all its children to `#shrink_to_fit = true` (shrink in
      # blessed), so a shrink-to-content widget with no usable width yet has free
      # width `s == 0` and must skip alignment padding. Gates on `width == 0`
      # because `width` is an Int, so blessed's falsy `!width` test can't port.
      s = (@shrink_to_fit && width == 0) ? 0 : width - len

      # Nothing to pad: return `line` unchanged, but pass on its now-known width
      # (`0` when all-SGR; `len` otherwise) so the caller skips a re-measure.
      return {line, 0} if len == 0
      return {line, len} if s < 0

      # Alignment's empty space is filled with the widget's `Style#fill_char`
      # (default `' '`), so a non-space fill (e.g. a dotted leader) lines up with
      # how the render loop fills trailing cells.
      fc = style.fill_char
      # The padded width is `len + s` only when each fill cell is one column (the
      # ASCII common case); for a wide fill char leave it unknown to be re-measured.
      padded_width = fc.ascii? ? len + s : nil

      if (align & Tput::AlignFlag::HCenter) != Tput::AlignFlag::None
        # Split free space across both sides; the odd extra cell goes right
        # (Blessed's convention), so a centered line fills `width` exactly instead
        # of falling one cell short on odd free space.
        lpad = s // 2
        rpad = s - lpad
        res = String.build(line.bytesize + s) do |io|
          lpad.times { io << fc }
          io << line
          rpad.times { io << fc }
        end
        return {res, padded_width}
      elsif align.right?
        res = String.build(line.bytesize + s) do |io|
          s.times { io << fc }
          io << line
        end
        return {res, padded_width}
      elsif align_left_too && align.left?
        # Left align is visually the same as no align, but center/right padding
        # affects widget size, so pad `{left}` too — making `{left|center|right}`
        # behave identically re. row width. Only when `{left}` is explicitly in
        # content with parse_tags on, never for a widget's default
        # `align = AlignFlag::Left` (which would disturb cursor position in text
        # widgets).
        res = String.build(line.bytesize + s) do |io|
          io << line
          s.times { io << fc }
        end
        return {res, padded_width}
      elsif @parse_tags && !@_content_no_tags && (line.includes?('{') || line.includes?('}'))
        # XXX This is basically Tput::AlignFlag::Spread, but not sure
        # how to put that as a flag yet. Maybe this (or another)
        # widget flag could mean to spread words to fill up the whole
        # line, increasing spaces between them?
        if res = split_right_align(line, cline, width)
          return {res, nil}
        end
        # Otherwise (lone `{` or `}`): falls through to `return line` below.
      end

      {line, len}
    end

    # Index of the first `{` or `}` in `s` at or after `from`, or `nil` if none.
    # The delimiter set of `split(/\{|\}/)`, located by `#index` (no regex, no
    # MatchData) so `#split_right_align` can pick out just the segments it needs.
    private def brace_after(s : String, from : Int32) : Int32?
      i = s.index('{', from)
      j = s.index('}', from)
      return j unless i
      return i unless j
      Math.min(i, j)
    end

    # Right-aligns text after a `{...}` split: the segment before the first
    # delimiter stays put, the segment after the second is pushed flush right
    # within `width`, gap filled by `Style#fill_char`. Backs both the `{|}`
    # right-align separator and the generic `{left}…{right}` spread.
    #
    # `line` is the raw (possibly SGR-carrying) line; `cline` is its SGR-stripped
    # form for width measurement. Returns `nil` when there's no usable two-sided
    # split (e.g. a lone `{` or `}`), and the caller leaves `line` unchanged.
    private def split_right_align(line, cline, width) : String?
      # Reproduce `split(/\{|\}/)`'s parts[0] (before the first brace) and
      # parts[2] (between the second and third brace, or to the string's end) via
      # index math, slicing only the two needed segments instead of materializing
      # two full split arrays. Braces never occur inside SGR runs, so `line` and
      # `cline` carry the same delimiters (at different indices); widths are
      # measured on the SGR-stripped `cline`, output taken from `line`.
      cb1 = brace_after(cline, 0)
      return unless cb1
      cb2 = brace_after(cline, cb1 + 1)
      # No second brace -> `split` yields no parts[2].
      return unless cb2
      cb3 = brace_after(cline, cb2 + 1)
      cpart0 = cline[0...cb1]
      cpart2 = cline[(cb2 + 1)...(cb3 || cline.size)]

      lb1 = brace_after(line, 0)
      lb2 = lb1 ? brace_after(line, lb1 + 1) : nil
      # `line` shares `cline`'s brace count, so both are present here.
      return unless lb1 && lb2
      lb3 = brace_after(line, lb2 + 1)
      lpart0 = line[0...lb1]
      lpart2 = line[(lb2 + 1)...(lb3 || line.size)]

      pad = style.fill_char.to_s * Math.max(width - str_width(cpart0) - str_width(cpart2), 0)
      "#{lpart0}#{pad}#{lpart2}"
    end
  end
end
