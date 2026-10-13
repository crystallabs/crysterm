module Crysterm
  class Widget
    # Word-wrapped, ready-to-render content lines plus the bookkeeping needed
    # to map between the original ("fake") and wrapped ("real") line numbers.
    #
    # Wraps rather than subclasses `Array(String)`: subclassing a stdlib generic
    # promotes every `Array(String)` in the program to the virtual type
    # `Array(String)+`, causing confusing compile errors elsewhere (issue #30).
    class CLines
      property string = ""
      property max_width = 0
      property width = 0

      # Right-edge columns (`Widget#content_margin_x`) these lines were wrapped to
      # avoid — the vertical scroll bar's reservation at wrap time. Part of the
      # convergence check in `Widget#process_content`.
      property margin = 0

      # Horizontal scroll offset (display columns) these lines were sliced for —
      # part of the wrap cache key, so scrolling forces a reparse like a width
      # change does. Only meaningful when `wrap_content` is off.
      property base_x = 0

      # Style inputs baked into the wrapped line text — TAB expansion
      # (`tab_char * tab_size`, `clean_content_chars`) and alignment padding
      # (`fill_char`, `align_line`/`split_right_align`). Part of the wrap cache key
      # so a style change (direct mutation + `update`, or a CSS cascade)
      # forces a rewrap; types match `Style#tab_char` (String) and
      # `Style#fill_char` (Char).
      property tab_size = 4
      property tab_char = " "
      property fill_char = ' '

      # Widest unclipped line in display columns (before horizontal viewport
      # slice). Drives `Widget#scroll_width` and the horizontal scroll bar's
      # range. `0` for wrapped content.
      property full_width = 0

      property content : String = ""

      # Version of the owning widget's `@content` that produced these wrapped
      # lines. Defaults to -1 so a fresh `CLines` never matches a real (>= 0)
      # version, forcing the first parse. `Int64` in lockstep with the widget's
      # `@_content_version`. See `Widget#process_content`.
      property content_version : Int64 = -1

      property real : CLines? = nil

      property fake = [] of String

      property ftor = [] of Array(Int32)
      property rtof = [] of Int32

      # Pool of recycled `ftor` sub-arrays, so steady-state reparsing reuses the
      # same `Array(Int32)` objects instead of allocating one per line per frame.
      # `#reset` drains rows here; `#take_ftor_row` hands them back out.
      @ftor_pool = [] of Array(Int32)

      # Defaults to `nil`, not an empty array: `process_content` always replaces
      # this with `_parse_attr`'s result on reparse. Readers go through
      # `attr.try(...)`.
      property attr : Array(Int64)? = nil

      # Backing store of wrapped lines. Array API (`push`, `[]`, `size`, `each`,
      # `join`, `reduce`, ...) is forwarded to it below.
      getter lines : Array(String)

      def initialize(@lines = [] of String)
      end

      # Clears the arrays a reparse refills in place, so this `CLines` is reused by
      # the next `wrap_lines` instead of allocating fresh. `clear` keeps each
      # array's backing buffer, so steady-state reparsing reallocates nothing here.
      # `fake`/`attr`/`real` and scalar fields are overwritten wholesale by the
      # reparse, so they are untouched.
      def reset : Nil
        @lines.clear
        @rtof.clear
        # Recycle per-line `ftor` sub-arrays instead of dropping them.
        @ftor.each do |row|
          row.clear
          @ftor_pool << row
        end
        @ftor.clear
      end

      # A cleared per-line `ftor` sub-array: recycled from the pool (see
      # `#reset`) when available, otherwise a fresh allocation.
      def take_ftor_row : Array(Int32)
        @ftor_pool.pop? || [] of Int32
      end

      # A fresh, independent copy of the lines, without the extra bookkeeping.
      # Defined explicitly since `dup` exists on `Object` and isn't forwarded.
      def dup
        @lines.dup
      end

      forward_missing_to @lines
    end

    # Scratch `CLines` reused across `append_content` calls so wrapping just the
    # appended line never allocates a fresh bookkeeping object.
    @_append_scratch : CLines? = nil

    # Appends `text` (one or more `\n`-separated logical lines) without reparsing
    # existing content. Only the new text is cleaned, tag-parsed, wrapped and
    # attr-scanned, then spliced onto `@wrapped_lines`'s tail — turning `set_content`'s
    # O(total) per-append cost into O(appended).
    #
    # Returns `true` if the fast path handled it, `false` if it bailed and the
    # caller must fall back to `set_content`/`append_line`.
    #
    # Byte-identical to a full reparse because:
    # * `wrap_lines` wraps each `\n`-split segment independently, so appending
    #   never re-wraps earlier lines.
    # * The segment is tag-parsed standalone only when the full reparse's tag
    #   stacks would be empty at the boundary anyway; otherwise it bails.
    # * Attributes do carry: an SGR left open on an earlier line (e.g. unclosed
    #   `{red-fg}`) colors appended lines too; `_attr_after` recreates that carry.
    def append_content(text : String) : Bool
      return false unless window?
      # Cache must be current: with a reparse pending, splicing onto stale
      # `@wrapped_lines` would corrupt it. Let the normal path run first.
      return false unless @wrapped_lines.content_version == @_content_version
      return false if content_blank?
      colwidth = @wrapped_lines.width
      return false if colwidth <= 0
      # A width change since the cache was built invalidates the existing wrapped
      # lines, so only the reparsing slow path can serve it.
      return false if (awidth - ihorizontal) != colwidth
      # Degenerate state: content cleaned to nothing leaves `wrap_lines` in its
      # empty-content shape (`fake` empty, one blank real line). Splicing there
      # would desync `fake` from `lines`.
      return false if @wrapped_lines.fake.empty?

      # An unclosed `{center}`/`{right}` opener mutates `wrap_lines`'s carried
      # `default_state` for all following lines in a full reparse, but the fast
      # path wraps the segment standalone from the widget's default `@align`,
      # dropping that carry. Bail conservatively whenever tag parsing is on and
      # alignment tags appear in existing content or the appended text.
      seg_has_align_tag = text.includes?('{') && text.matches?(ALIGN_TAG_REGEX)
      if @parse_tags && (@_content_has_align_tag || seg_has_align_tag)
        return false
      end

      # Clean control chars on just the appended text (same rule as
      # `process_content`), then tag-parse only the new segment.
      seg = clean_content_chars text
      # An append that cleans away to nothing would drive `wrap_lines` down its
      # empty-content branch, desyncing `fake` from `lines`.
      return false if seg.empty?

      # Decided on the raw `text`, NOT the cleaned `seg`, mirroring how
      # `set_content` derives `@_content_has_tags`: a full reparse's `expand_tags`
      # gate keys off the raw string, so this decision must too (a control char
      # inside a would-be tag makes the raw string tagless even though cleaning
      # would form a tag).
      seg_has_tags = text.includes?('{') && text.matches?(TAG_REGEX)

      # Tag-parse the new segment iff a full reparse of (existing + appended)
      # content would run `expand_tags` — the same gate as `process_content`, with
      # the appended text folded into the tag flag.
      if @parse_tags && !@_content_no_tags && (@_content_has_tags || seg_has_tags) &&
         (seg.includes?('{') || seg.includes?('}'))
        # This append switches the reparse gate on over content that was never
        # tag-parsed. That only matters if existing raw content has a brace: kept
        # literal so far, it would now be dropped by the drop-malformed policy,
        # changing already-rendered lines. Brace-free existing content is
        # unaffected by the flip, so it stays on the fast path. The slow path's
        # `raw_fake_lines` capture escapes those never-parsed braces
        # (`{` → `{open}`) so they keep rendering literally, and its rebuild
        # re-derives `@_content_has_tags` from the raw (tag-carrying) content —
        # true from then on, so this bails at most once.
        return false if !@_content_has_tags && @_content_has_braces
        # A full reparse carries raw `@content`'s tag stacks (and `{escape}` mode)
        # across the append boundary; the fast path parses the segment standalone,
        # from empty state. Opening tags emit the same SGR either way, but a
        # closing tag pops the carried stack (restoring e.g. a still-open
        # `{red-fg}` rather than emitting the off-SGR), and an open escape
        # swallows the segment verbatim.
        return false if @_content_open_tags_at_end
        # Boundary state is empty (just checked), so the standalone parse matches
        # a full reparse exactly — including dropping stray braces and unknown
        # tags — and its end state is the new boundary state.
        seg = expand_tags seg
        @_content_open_tags_at_end = @expand_tags_left_open
        # A segment that parses away to nothing (e.g. a lone unknown tag) hits the
        # same `fake`/`lines` desync as the cleaned-to-empty case above.
        return false if seg.empty?
      end

      # Wrap only the appended segment into a scratch CLines.
      scratch = (@_append_scratch ||= CLines.new)
      wrap_lines(seg, colwidth, into: scratch)

      cl = @wrapped_lines
      base_real = cl.lines.size
      base_fake = cl.fake.size

      # Splice the scratch's real lines, fake lines and mappings onto the tail,
      # offsetting the indices by where the existing content ends. `lines`/`fake`
      # need no offset (bulk `concat`); `ftor`/`rtof` are renumbered.
      cl.lines.concat scratch.lines
      cl.fake.concat scratch.fake
      scratch.ftor.each do |row|
        cl.ftor << row.map { |r| r + base_real }
      end
      scratch.rtof.each { |f| cl.rtof << (f + base_fake) }

      # Per-line starting attrs for new lines, carrying SGR state across the
      # boundary: first new line starts from the attr the existing content ended
      # on, each subsequent line continues from the previous — matching
      # `_parse_attr`'s line-to-line carry.
      #
      # SGR-free content carries no attr array at all (`_parse_attr` returns
      # `nil`: every line starts at the base attr, which is the reader's
      # fallback). An appended segment that first introduces SGR (raw, or
      # expanded from a tag above) must materialize it — the existing lines'
      # start attrs are all the base attr — or the carry below has nowhere to
      # land and the segment's later lines would lose their colors. A segment
      # without SGR extends the all-default state, so `nil` stays.
      if cl.attr.nil? && seg.includes?('\e')
        da0 = style_to_attr(style)
        cl.attr = Array(Int64).new(base_real, da0)
      end
      if attrs = cl.attr
        da = style_to_attr(style)
        # `base_real >= 1` (content non-blank); degrade to default if `attrs` is
        # somehow short.
        carry = base_real <= attrs.size ? _attr_after(cl.lines[base_real - 1], attrs[base_real - 1], da) : da
        scratch.lines.each do |ln|
          attrs << carry
          carry = _attr_after(ln, carry, da)
        end
      end

      cl.max_width = Math.max(cl.max_width, scratch.max_width)
      # Carry the widest unclipped line forward too (non-wrapped content only;
      # `full_width` is 0 when wrapping), or a wider appended line would leave the
      # horizontal scroll extent stale.
      cl.full_width = Math.max(cl.full_width, scratch.full_width)

      # Defer the two O(total) string builds, making a run of appends O(1)
      # amortized rather than O(n) each: `@printable_content` is marked stale and rebuilt
      # on demand (a fresh String also makes render's `built_from?` check rebuild
      # the codepoint index), and the raw `text` is folded into `@content` only
      # when read.
      @printable_content = nil
      @_content_tail << text
      # Content-shape flags accumulate from the raw appended text under the same
      # conditions `set_content` uses — independent of `@parse_tags`/`no_tags`
      # mode. Tags appended while parsing is off (kept literal above) must still
      # set the flags, or a later `parse_tags = true` flip reparses with a
      # stale-false gate and the tags stay literal permanently.
      @_content_has_tags ||= seg_has_tags
      @_content_has_braces ||= text.includes?('{') || text.includes?('}')
      @_content_has_align_tag ||= seg_has_align_tag
      # Cleaned `seg` retains valid SGR (stray ESC was stripped above);
      # tag-expanded SGR is covered by `@_content_has_tags`, as in `set_content`.
      @_content_has_sgr ||= seg.includes? '\e'
      @_content_version += 1
      cl.content_version = @_content_version

      # If the appended lines crossed the viewport-overflow threshold, an
      # `AsNeeded` vertical scroll bar just flipped on (or off) and
      # `content_margin_x` changed, leaving every line wrapped against the
      # pre-flip margin. Reconcile immediately with one full reparse: stale-margin
      # lines otherwise survive until the next `process_content` and desync readers
      # running off the events emitted just below. Rare — only the append that
      # crosses the threshold pays this; once the bar's presence is stable,
      # subsequent appends stay on the O(appended) fast path.
      if cl.margin != content_margin_x
        process_content
      end

      # Mirror the full path: mark for repaint and emit the same events.
      update
      emit Crysterm::Event::ContentParsed
      emit Crysterm::Event::ContentSet
      true
    end

    # The raw logical lines, index-aligned with `@wrapped_lines.fake`. Reused
    # across line replacements; re-split from the (folded) content only after
    # it was rewritten wholesale or appended to.
    private def raw_content_lines : Array(String)
      if (lines = @_content_raw_lines) && @_content_tail.empty?
        return lines
      end
      fold_content_tail
      @_content_raw_lines = @content.split(RAW_LINE_REGEX)
    end

    # Replaces logical line *fake* with *text* (one line: no newline) without
    # reparsing the rest of the content — the per-keystroke path of a
    # multi-line editor. Only the new line is cleaned and wrapped; its rows
    # are spliced over the old ones in `@wrapped_lines`, the row maps after
    # it are renumbered, and the raw content is left to be re-joined lazily
    # (`@_content_stale`). O(line + rows after it) rather than O(buffer).
    #
    # Returns `true` if the fast path handled it, `false` if it bailed and the
    # caller must fall back to `set_content`. Byte-identical to a full reparse
    # under the conditions it accepts (`#content_line_replaceable?`): no tag
    # parsing in play (tags are expanded with cross-line state), no inline
    # SGR anywhere (so no attr carry), and a result that keeps the content
    # non-empty.
    def replace_content_line(fake : Int32, text : String) : Bool
      return false if text.includes?('\n')
      replace_content_lines fake, 1, text
    end

    # Replaces the *count* logical lines from *fake* on with *text*, whose
    # `'\n'`s make it as many lines as it holds plus one — the path of an
    # edit that joins or splits lines (Qt's `contentsChange(pos, removed,
    # added)` relaid over the blocks it touched). As `#replace_content_line`,
    # whose conditions it shares: O(new lines + rows after them).
    def replace_content_lines(fake : Int32, count : Int32, text : String) : Bool
      return false unless content_line_replaceable?(fake, count, text)
      cl = @wrapped_lines
      seg = clean_content_chars text
      # Content that would clean away entirely takes the empty-content shape
      # (`fake` empty, one blank row), which only a full wrap produces.
      return false if seg.empty? && cl.fake.size == count

      # Wrap just the new lines, at the width and bar reservation the cached
      # lines were wrapped with.
      scratch = (@_append_scratch ||= CLines.new)
      wrap_lines(seg, cl.width, into: scratch, margin: cl.margin)
      return false if scratch.lines.empty?
      # An empty *seg* is wrapped as empty content (no fake lines, one
      # blank row): as a line among others it is one empty line.
      new_fake = seg.empty? ? [""] : scratch.fake
      raw = count == 1 && new_fake.size == 1 ? nil : text.split('\n')
      return false if raw && raw.size != new_fake.size
      splice_content_rows cl, fake, count, new_fake, scratch

      # The raw side: the lines are recorded, the joined string re-built only
      # when read. Content-shape flags accumulate like `append_content`'s.
      if raw
        raw_content_lines[fake, count] = raw
      else
        raw_content_lines[fake] = text
      end
      @_content_stale = true
      @printable_content = nil
      @_content_has_tags ||= text.includes?('{') && text.matches?(TAG_REGEX)
      @_content_has_braces ||= text.includes?('{') || text.includes?('}')
      @_content_has_align_tag ||= text.includes?('{') && text.matches?(ALIGN_TAG_REGEX)
      @_content_version += 1
      cl.content_version = @_content_version

      # A row-count change can flip an `AsNeeded` bar on or off, changing the
      # width every line wraps at: reconcile with one full reparse, as
      # `append_content` does.
      if cl.margin != content_margin_x
        process_content
      end

      update
      emit Crysterm::Event::ContentParsed
      emit Crysterm::Event::ContentSet
      true
    end

    # The guards of `#replace_content_lines`: a current wrap cache at the
    # live width and scroll, existing lines to replace, and content whose
    # lines wrap independently of each other.
    private def content_line_replaceable?(fake : Int32, count : Int32, text : String) : Bool
      return false unless window?
      cl = @wrapped_lines
      return false unless cl.content_version == @_content_version
      return false if content_blank?
      colwidth = cl.width
      return false if colwidth <= 0
      return false if (awidth - ihorizontal) != colwidth
      return false if cl.base_x != @child_base_x
      return false if count < 1 || fake < 0 || fake + count > cl.fake.size
      return false if text.includes?('\r')
      # A tag-parsing widget only takes brace-free text over brace-free
      # content: `expand_tags` carries state across lines.
      if @parse_tags && !@_content_no_tags
        return false if @_content_has_braces || text.includes?('{') || text.includes?('}')
      end
      # Inline SGR colors the lines after it (`_parse_attr`'s carry); with
      # none anywhere every row starts at the base attr and `attr` needs no
      # recompute.
      return false if @_content_has_sgr || text.includes?('\e')
      return false unless raw_content_lines.size == cl.fake.size
      !cl.ftor[fake].empty? && !cl.ftor[fake + count - 1].empty?
    end

    # Splices *scratch*'s rows (the freshly wrapped lines *new_fake*) over
    # the rows of the *count* fake lines from *fake* on in *cl*, renumbering
    # the row maps after them and keeping the widest-row records current.
    private def splice_content_rows(cl : CLines, fake : Int32, count : Int32, new_fake : Array(String), scratch : CLines) : Nil
      new_lines = scratch.lines
      n_new = new_lines.size
      ftor = cl.ftor
      r0 = ftor[fake].first
      n_old = ftor[fake + count - 1].last + 1 - r0
      nf_new = new_fake.size
      lines = cl.lines

      # Widths of the rows and lines being replaced, before they go.
      old_max = 0
      n_old.times do |i|
        w = str_width(lines[r0 + i])
        old_max = w if w > old_max
      end
      old_full = 0
      unless @wrap_content
        count.times { |i| old_full = Math.max(old_full, str_width(cl.fake[fake + i])) }
      end

      # Rows, fake lines, and the row→fake map: the new rows map to their
      # own lines, the rows after them shift by the line delta.
      lines[r0, n_old] = new_lines
      cl.fake[fake, count] = new_fake
      fdelta = nf_new - count
      rtof = cl.rtof
      if fdelta != 0 || nf_new != 1 || n_new != n_old
        rtof[r0, n_old] = scratch.rtof.map(&.+(fake))
        if fdelta != 0
          j = r0 + n_new
          while j < rtof.size
            rtof[j] += fdelta
            j += 1
          end
        end
      end
      # With no SGR anywhere, an existing attr array (built because the raw
      # text carries tag-shaped braces) holds the base attr on every row.
      if (attrs = cl.attr) && n_new != n_old
        attrs[r0, n_old] = Array.new(n_new, attrs[r0])
      end
      # The fake→rows map: the replaced lines' row lists are rebuilt (in
      # place while the line count holds), the lines after them shift by
      # the row delta.
      if fdelta == 0
        nf_new.times do |i|
          row = ftor[fake + i]
          row.clear
          scratch.ftor[i].each { |r| row << r + r0 }
        end
      else
        ftor[fake, count] = scratch.ftor.map(&.map(&.+(r0)))
      end
      delta = n_new - n_old
      if delta != 0
        j = fake + nf_new
        while j < ftor.size
          ftor.unsafe_fetch(j).map! { |r| r + delta }
          j += 1
        end
      end

      # The widest row: taken from the new rows when they reach it, re-scanned
      # only when the replaced rows held the record and the new ones fall
      # short of it.
      if scratch.max_width >= cl.max_width
        cl.max_width = scratch.max_width
      elsif old_max >= cl.max_width
        cl.max_width = widest_up_to(lines, cl.max_width)
      end
      # :ditto: for the unclipped width (unwrapped content only).
      unless @wrap_content
        if scratch.full_width >= cl.full_width
          cl.full_width = scratch.full_width
        elsif old_full >= cl.full_width
          cl.full_width = widest_up_to(cl.fake, cl.full_width)
        end
      end
    end

    # The display width of the widest of *strs*, which is at most *record*:
    # the scan stops at the first that reaches it — another row at the
    # record a replaced one held, which wrapped rows filling the width
    # usually are — and reads all of them only when none does.
    private def widest_up_to(strs : Array(String), record : Int32) : Int32
      widest = 0
      strs.each do |str|
        w = str_width(str)
        next unless w > widest
        widest = w
        break if widest >= record
      end
      widest
    end
  end
end
