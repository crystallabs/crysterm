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
      property ci = [] of Int32

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
        @ci.clear
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

      # Extend `ci` (char offset of each real line in the joined pcontent). Must
      # derive from the existing offsets, not `@printable_content`, which is lazily built
      # and may be stale/nil here. The first new line starts one past the last
      # existing line's end (the +1 is the joining "\n"); `base_real >= 1` since
      # content is non-blank. The safe `[]?` keeps offsets monotonic rather than
      # raising should `ci` somehow be short.
      running = (cl.ci[base_real - 1]? || 0) + cl.lines[base_real - 1].size + 1
      scratch.lines.each do |ln|
        cl.ci << running
        running += ln.size + 1
      end

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
  end
end
