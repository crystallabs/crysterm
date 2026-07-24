module Crysterm
  class Widget
    # Scratch `CLines` reused across `append_content` calls so wrapping just the
    # appended line never allocates a fresh bookkeeping object.
    @_append_scratch : CLines? = nil

    # Appends `text` (one or more `\n`-separated logical lines) without reparsing
    # existing content. Only the new text is cleaned, tag-parsed, wrapped and
    # attr-scanned, then spliced onto `@_clines`'s tail — turning `set_content`'s
    # O(total) per-append cost into O(appended).
    #
    # Returns `true` if the fast path handled it, `false` if it bailed and the
    # caller must fall back to `set_content`/`append_line`.
    #
    # Byte-identical to a full reparse because:
    # * `_wrap_content` wraps each `\n`-split segment independently, so appending
    #   never re-wraps earlier lines.
    # * The segment is tag-parsed standalone only when the full reparse's tag
    #   stacks would be empty at the boundary anyway; otherwise it bails.
    # * Attributes do carry: an SGR left open on an earlier line (e.g. unclosed
    #   `{red-fg}`) colors appended lines too; `_attr_after` recreates that carry.
    def append_content(text : String) : Bool
      return false unless window?
      # Cache must be current: with a reparse pending, splicing onto stale
      # `@_clines` would corrupt it. Let the normal path run first.
      return false unless @_clines.content_version == @_content_version
      return false if content_blank?
      colwidth = @_clines.width
      return false if colwidth <= 0
      # A width change since the cache was built invalidates the existing wrapped
      # lines, so only the reparsing slow path can serve it.
      return false if (awidth - ihorizontal) != colwidth
      # Degenerate state: content cleaned to nothing leaves `_wrap_content` in its
      # empty-content shape (`fake` empty, one blank real line). Splicing there
      # would desync `fake` from `lines`.
      return false if @_clines.fake.empty?

      # An unclosed `{center}`/`{right}` opener mutates `_wrap_content`'s carried
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
      # An append that cleans away to nothing would drive `_wrap_content` down its
      # empty-content branch, desyncing `fake` from `lines`.
      return false if seg.empty?

      # Decided on the raw `text`, NOT the cleaned `seg`, mirroring how
      # `set_content` derives `@_content_has_tags`: a full reparse's `_parse_tags`
      # gate keys off the raw string, so this decision must too (a control char
      # inside a would-be tag makes the raw string tagless even though cleaning
      # would form a tag).
      seg_has_tags = text.includes?('{') && text.matches?(TAG_REGEX)

      # Tag-parse the new segment iff a full reparse of (existing + appended)
      # content would run `_parse_tags` — the same gate as `process_content`, with
      # the appended text folded into the tag flag.
      if @parse_tags && !@_content_no_tags && (@_content_has_tags || seg_has_tags) &&
         (seg.includes?('{') || seg.includes?('}'))
        # This append switches the reparse gate on over content that was never
        # tag-parsed. That only matters if existing raw content has a brace: kept
        # literal so far, it would now be dropped by the drop-malformed policy,
        # changing already-rendered lines. Brace-free existing content is
        # unaffected by the flip, so it stays on the fast path. Testing
        # `@_content_has_tags` alone would bail here forever rather than once: the
        # rebuild re-derives that flag from POST-parse text, where tags have
        # already become SGR, so it lands back on false after every fallback.
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
        seg = _parse_tags seg
        @_content_open_tags_at_end = @_parse_tags_left_open
        # A segment that parses away to nothing (e.g. a lone unknown tag) hits the
        # same `fake`/`lines` desync as the cleaned-to-empty case above.
        return false if seg.empty?
      end

      # Wrap only the appended segment into a scratch CLines.
      scratch = (@_append_scratch ||= CLines.new)
      _wrap_content(seg, colwidth, into: scratch)

      cl = @_clines
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
      # derive from the existing offsets, not `@_pcontent`, which is lazily built
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
      # amortized rather than O(n) each: `@_pcontent` is marked stale and rebuilt
      # on demand (a fresh String also makes render's `built_from?` check rebuild
      # the codepoint index), and the raw `text` is folded into `@content` only
      # when read.
      @_pcontent = nil
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
      mark_dirty
      emit Crysterm::Event::ContentParsed
      emit Crysterm::Event::ContentChanged
      true
    end

    # Appends *line* after the last logical line. Splits on `\n` for multi-line
    # input.
    def insert_line(line : String) : Nil
      insert_line(@_clines.fake.size, line)
    end

    def insert_line(index : Int32, line : String) : Nil
      lines = line.split("\n")

      i = Math.max(index, 0)

      while @_clines.fake.size < i
        @_clines.fake.push("")
        @_clines.ftor.push([@_clines.push("").size - 1])
        # Discarded read kept only for parity with the port; the safe `[]?` so it
        # cannot raise when `rtof` is shorter than `fake`.
        @_clines.rtof[@_clines.fake.size - 1]?
      end

      # NOTE: Could possibly compare the first and last ftor line numbers to see
      # if they're the same, or if they fit in the visible region entirely.
      start = @_clines.size
      # diff
      # real

      if i >= @_clines.ftor.size
        # `ftor` is empty before the first wrap (freshly built widget, or content
        # cleared to empty), where `ftor[-1]` would raise. Default the insert point
        # to the first real line.
        if last_row = @_clines.ftor.last?
          real = last_row[-1] + 1
        else
          real = 0
        end
      else
        real = @_clines.ftor[i][0]
      end

      lines.size.times do |j|
        # Pre-parse each incoming line into the POST-parse form `fake` holds, so
        # the reparse-suppressed rebuild below still expands this line's tags
        # without re-running (and corrupting) the other lines.
        @_clines.fake.insert(i + j, parse_fake_line(lines[j]))
      end

      rebuild_content_from_fake

      diff = @_clines.size - start

      render_line_shift(diff, real) do |d, y, top, bottom|
        window.insert_line(d, y, top, bottom)
      end
    end

    # Drives the terminal-side line insert/delete optimization. *diff* is the
    # change in wrapped-line count (only acts when positive) and *real* the
    # affected real (wrapped) line index. Computes the on-window coordinates and,
    # when the affected row is visible and the sides are clean, yields
    # `(diff, y, top, bottom)` for the caller's window op. A no-op (no yield) when
    # the widget isn't laid out or the row is off the viewport.
    private def render_line_shift(diff, real, &)
      return unless diff > 0
      pos = coords
      return if !pos || pos == 0

      height = pos.yl - pos.yi - ivertical
      base = @child_base
      visible = real >= base && real - base < height

      top = pos.yi
      bottom = pos.yl - ibottom - 1
      # The vertical bounds check is load-bearing: `sides_uniform?`'s full-width
      # shortcut skips vertical bounds, but the window line ops mutate buffer rows
      # `top..bottom` directly, so out-of-buffer bounds raise mid-mutation (or wrap
      # negative indices), corrupting the line buffers. A widget extending past the
      # screen edge falls back to the normal repaint.
      if visible && top >= 0 && bottom <= window.aheight - 1 && window.sides_uniform?(self)
        yield diff, pos.yi + itop + real - base, top, bottom
      end
    end

    # Deletes the last logical line (Blessed's `deleteLine()` no-argument
    # behavior). A zero-arg def, not `(n : Int32 = 1)`: that signature would be
    # merged with the `(index, n)` overload below and replace it.
    def delete_line : Nil
      return if @_clines.fake.empty?
      delete_line(@_clines.fake.size - 1, 1)
    end

    def delete_line(index : Int32, n : Int32 = 1) : Nil
      # Nothing to delete when there are no logical lines yet (freshly built
      # widget, or content cleared to empty); without this guard the deletes below
      # raise on such a widget. Blessed's `deleteLine` is a no-op here.
      return if @_clines.fake.empty?

      # Clamp against the array actually spliced below (`fake`), NOT `ftor`: with
      # content seeded before attach, `fake` is non-empty while `ftor` is still
      # empty, so `ftor.size - 1 == -1` and Crystal's two-arg `clamp` (which
      # returns `max` when `min > max`) would make `i` be `-1`, deleting the LAST
      # line.
      i = index.clamp(0, @_clines.fake.size - 1)

      # Clamp count to lines actually available from `i`, or deleting more than
      # remain runs `delete_at` off the end of `fake`. JS `splice(i, n)` clamps,
      # so this matches the ported Blessed semantics.
      n = Math.min(n, @_clines.fake.size - i)
      return if n <= 0

      # NOTE: Could possibly compare the first and last ftor line numbers to see
      # if they're the same, or if they fit in the visible region entirely.
      start = @_clines.size
      # `ftor` is empty when content was seeded before attach (`fake` gets filled
      # but `process_content` bails until the widget has a window), so `ftor[i]`
      # would raise despite `fake` being non-empty. Fall back to real line 0; the
      # fake splice + rebuild below still works.
      real = @_clines.ftor[i]?.try(&.[0]?) || 0

      n.times { @_clines.fake.delete_at i }

      rebuild_content_from_fake

      diff = start - @_clines.size

      # XXX clear_last_rendered_position() without diff statement?
      render_line_shift(diff, real) do |d, y, top, bottom|
        window.delete_line(d, y, top, bottom)
      end
    end

    # Maps a real (wrapped) line index to its fake (logical) line index,
    # guarding out-of-range access (e.g. before content is wrapped). Returns 0
    # when `rtof` is empty, clamps otherwise.
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
      # `visible_content_rows`, not `aheight - ivertical`: it subtracts the
      # horizontal scroll bar's reserved row, so we don't insert after a line
      # hidden under the bar.
      h = @child_base + visible_content_rows
      i = Math.min(h, @_clines.size)
      fake = rtof_index(i - 1) + 1

      insert_line(fake, line)
    end

    def delete_top(n = 1)
      fake = rtof_index(@child_base)
      delete_line(fake, n)
    end

    def delete_bottom(n : Int32 = 1)
      # `visible_content_rows` accounts for the horizontal scroll bar's reserved
      # row, so we delete the visible bottom row, not one hidden below the bar.
      h = @child_base + visible_content_rows - 1
      i = Math.min(h, @_clines.size - 1)
      fake = rtof_index(i)

      delete_line(fake - (n - 1), n)
    end

    def replace_line(i, line)
      i = Math.max(i, 0)
      # Pad up to and including index `i` (`<=`, not `<`). Blessed relies on JS
      # auto-extending arrays; Crystal's `fake[i] = line` raises when `i ==
      # fake.size`, so the slot must exist first.
      while @_clines.fake.size <= i
        @_clines.fake.push("")
      end
      # Pre-parse into `fake`'s POST-parse form so the reparse-suppressed rebuild
      # keeps the other lines intact.
      @_clines.fake[i] = parse_fake_line(line)
      rebuild_content_from_fake
    end

    def replace_base_line(i, line)
      fake = rtof_index(@child_base)
      replace_line(fake + i, line)
    end

    # Original ("fake") line *i*, as rendered (see `#rendered_content`).
    def line(i)
      # Empty content leaves `@_clines.fake` empty, where `i.clamp(0, fake.size - 1)`
      # clamps to `-1` (Crystal's two-arg clamp yields `max` even when `min > max`)
      # and `fake[-1]` would raise. A blank line matches Blessed's `getLine` for a
      # missing line.
      return "" if @_clines.fake.empty?
      i = i.clamp(0, @_clines.fake.size - 1)
      @_clines.fake[i]
    end

    # `#line`, but *i* counts from the current scroll base rather than from the
    # top of the content.
    def base_line(i)
      fake = rtof_index(@child_base)
      line(fake + i)
    end

    def clear_line(i)
      i = Math.min(i, @_clines.fake.size - 1)
      replace_line(i, "")
    end

    def clear_base_line(i)
      fake = rtof_index(@child_base)
      clear_line(fake + i)
    end

    def prepend_line(line)
      insert_line(0, line)
    end

    def remove_first_line(n)
      delete_line(0, n)
    end

    def append_line(line)
      # Seed line 0 when there is no content yet (counting deferred appends
      # without materializing them).
      if content_blank?
        return replace_line(0, line)
      end
      # Appending at the end is the common case (logs, transcripts, streaming
      # output), so try the O(appended) splice first; it returns false and falls
      # through to the general insert when it can't guarantee an identical result.
      #
      # NOTE: there is deliberately no `Widget#<<` text alias — `<<` already means
      # "append a child widget".
      return if append_content(line)
      insert_line(@_clines.fake.size, line)
    end

    def remove_last_line(n)
      delete_line(@_clines.fake.size - 1, n)
    end

    # All original ("fake") lines, as rendered. A copy; mutating it does not
    # touch the widget.
    def lines
      @_clines.fake.dup
    end

    # All *wrapped* ("real") lines — one entry per screen row rather than per
    # original line. A copy; see `#lines` for the unwrapped view.
    def screen_lines
      @_clines.dup
    end
  end
end
