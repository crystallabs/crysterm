module Crysterm
  module Mixin
    # The Blessed-era **logical-line editing** surface: `insert_line`,
    # `delete_line`, `replace_line`, `append_line`, `line`/`lines`/`screen_lines`
    # and friends. They splice the widget's RAW logical lines and rebuild the
    # content wholesale, so they are meaningful only for widgets that *display
    # text content*.
    #
    # Included by `Widget::Box` (and therefore by every content-displaying
    # widget in the tree — `Log`, `ScrollableText`, `Gauge`, `Chat::Transcript`,
    # …), NOT by the `Widget` base: a `Spacer` or a `Terminal` has no logical
    # lines to edit. A custom `Widget` subclass that wants them can
    # `include Crysterm::Mixin::LineContent`.
    #
    # Requires the content pipeline of `Widget` itself (`#content`,
    # `#set_content`, `@wrapped_lines`, `#append_content`) plus the scrolling
    # helpers (`#visible_content_rows`, `#csr_region_for`), all of which the
    # base class provides.
    module LineContent
      # The RAW (pre-parse) logical lines backing the fake-line editors
      # (`insert_line`/`delete_line`/`replace_line`/...): raw `#content` split at
      # the same line boundaries `clean_content_chars` normalizes
      # (`RAW_LINE_REGEX`), so index `i` here addresses the same logical line as
      # the parsed `@wrapped_lines.fake[i]`. The editors splice THESE lines and rebuild
      # via `#rebuild_content_from_raw`; `@content` therefore never holds
      # post-parse text, and any later cache-miss reparse (width change, resize,
      # scroll, re-attach, style change) re-runs `expand_tags` over true raw
      # source — escaped braces (`{open}`/`{close}`, `{escape}` bodies) survive
      # every reparse instead of only the first.
      #
      # Empty `@wrapped_lines.fake` means the widget currently renders no logical lines
      # (no content at all, or content whose cleaned/parsed form is empty). The
      # editors index off `fake`, so mirror that here as "no raw lines"; an edit
      # then discards such invisible content.
      #
      # Never-parsed literal braces: with tag parsing on but no recognized tag in
      # the content (`@_content_has_tags` false), stray braces render literally
      # because `process_content` skips `expand_tags`. An edit may splice in a
      # line WITH tags, flipping that gate on — reparsing the plain raw text
      # would then drop the old braces (drop-malformed policy), silently
      # rewriting already-rendered lines (pinned by
      # spec/bugs12_append_content_tags_spec.cr). Escape them (`{` → `{open}`,
      # `}` → `{close}`) at capture time, so they reparse to the same literal
      # braces no matter what the edit adds. Self-limiting: the escaped form IS
      # tagged, so `@_content_has_tags` lands true after the first such edit and
      # the regime is never re-entered (no double escaping).
      private def raw_fake_lines : Array(String)
        return [] of String if @wrapped_lines.fake.empty?
        lines = content.split(Widget::RAW_LINE_REGEX)
        if @parse_tags && !@_content_no_tags && !@_content_has_tags && @_content_has_braces
          lines.map! { |l| Widget.escape_tags(l) }
        end
        lines
      end

      # Rebuilds widget content from the raw logical lines a line editor has just
      # spliced (see `#raw_fake_lines`), by re-setting them as the widget's raw
      # content and running a NORMAL full reparse — *raw* is pre-parse source
      # text, so nothing here needs to suppress `expand_tags`, and repeated later
      # reparses of the same content stay byte-identical.
      private def rebuild_content_from_raw(raw : Array(String)) : Nil
        # `no_tags:` MUST carry the widget's tag mode: letting it default to false
        # would permanently flip a literal-tags widget back into tag-parsing mode.
        set_content(raw.join('\n'), no_tags: @_content_no_tags)
      end

      # Appends *line* after the last logical line. Splits on `\n` for multi-line
      # input.
      def insert_line(line : String) : Nil
        insert_line(@wrapped_lines.fake.size, line)
      end

      def insert_line(index : Int32, line : String) : Nil
        lines = line.split("\n")

        i = Math.max(index, 0)

        # The editors splice RAW logical lines (see `#raw_fake_lines`); `fake`
        # and everything else derived from content is re-built from them by the
        # full reparse in `rebuild_content_from_raw`.
        raw = raw_fake_lines

        while raw.size < i
          raw.push("")
          # Mirror the padding into the wrapped lines so the `start`/`diff` math
          # below counts the padded rows as pre-existing content, not as part of
          # the insert (the rebuild's reparse replaces them anyway).
          @wrapped_lines.ftor.push([@wrapped_lines.push("").size - 1])
        end

        # NOTE: Could possibly compare the first and last ftor line numbers to see
        # if they're the same, or if they fit in the visible region entirely.
        start = @wrapped_lines.size
        # diff
        # real

        if i >= @wrapped_lines.ftor.size
          # `ftor` is empty before the first wrap (freshly built widget, or content
          # cleared to empty), where `ftor[-1]` would raise. Default the insert point
          # to the first real line.
          if last_row = @wrapped_lines.ftor.last?
            real = last_row[-1] + 1
          else
            real = 0
          end
        else
          real = @wrapped_lines.ftor[i][0]
        end

        lines.size.times do |j|
          # Splice the RAW line; tags in it are expanded by the rebuild's full
          # reparse, exactly as a `set_content` of the same total text would.
          raw.insert(i + j, lines[j])
        end

        rebuild_content_from_raw raw

        diff = @wrapped_lines.size - start

        render_line_shift(diff, real) do |d, y, top, bottom|
          window.scroll_insert_rows(d, y, top, bottom)
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
        return unless real >= base && real - base < height

        # `csr_region_for` (widget_scrolling.cr) validates the region against
        # the buffer-corruption hazards of the direct window line ops
        # (out-of-buffer bounds, non-uniform sides); on nil the widget falls
        # back to the normal repaint.
        if region = csr_region_for(pos.yi, pos.yl - ibottom - 1)
          top, bottom = region
          yield diff, pos.yi + itop + real - base, top, bottom
        end
      end

      # Deletes the last logical line (Blessed's `deleteLine()` no-argument
      # behavior). A zero-arg def, not `(n : Int32 = 1)`: that signature would be
      # merged with the `(index, n)` overload below and replace it.
      def delete_line : Nil
        return if @wrapped_lines.fake.empty?
        delete_line(@wrapped_lines.fake.size - 1, 1)
      end

      def delete_line(index : Int32, n : Int32 = 1) : Nil
        # The editors splice RAW logical lines, kept index-aligned with `fake`
        # (see `#raw_fake_lines`).
        raw = raw_fake_lines

        # Nothing to delete when there are no logical lines yet (freshly built
        # widget, or content cleared to empty); without this guard the deletes below
        # raise on such a widget. Blessed's `deleteLine` is a no-op here.
        return if raw.empty?

        # Clamp against the array actually spliced below (`raw`), NOT `ftor`: with
        # content seeded before attach, the lines are non-empty while `ftor` is
        # still empty, so `ftor.size - 1 == -1` and Crystal's two-arg `clamp`
        # (which returns `max` when `min > max`) would make `i` be `-1`, deleting
        # the LAST line.
        i = index.clamp(0, raw.size - 1)

        # Clamp count to lines actually available from `i`, or deleting more than
        # remain runs `delete_at` off the end. JS `splice(i, n)` clamps, so this
        # matches the ported Blessed semantics.
        n = Math.min(n, raw.size - i)
        return if n <= 0

        # NOTE: Could possibly compare the first and last ftor line numbers to see
        # if they're the same, or if they fit in the visible region entirely.
        start = @wrapped_lines.size
        # `ftor` is empty when content was seeded before attach (`fake` gets filled
        # but `process_content` bails until the widget has a window), so `ftor[i]`
        # would raise despite the content being non-empty. Fall back to real line
        # 0; the raw splice + rebuild below still works.
        real = @wrapped_lines.ftor[i]?.try(&.[0]?) || 0

        n.times { raw.delete_at i }

        rebuild_content_from_raw raw

        diff = start - @wrapped_lines.size

        # XXX clear_last_rendered_position() without diff statement?
        render_line_shift(diff, real) do |d, y, top, bottom|
          window.scroll_delete_rows(d, y, top, bottom)
        end
      end

      # Maps a real (wrapped) line index to its fake (logical) line index,
      # guarding out-of-range access (e.g. before content is wrapped). Returns 0
      # when `rtof` is empty, clamps otherwise.
      private def rtof_index(i)
        rtof = @wrapped_lines.rtof
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
        i = Math.min(h, @wrapped_lines.size)
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
        i = Math.min(h, @wrapped_lines.size - 1)
        fake = rtof_index(i)

        delete_line(fake - (n - 1), n)
      end

      def replace_line(i, line)
        i = Math.max(i, 0)
        # The editors splice RAW logical lines, kept index-aligned with `fake`
        # (see `#raw_fake_lines`).
        raw = raw_fake_lines
        # Pad up to and including index `i` (`<=`, not `<`). Blessed relies on JS
        # auto-extending arrays; Crystal's `raw[i] = line` raises when `i ==
        # raw.size`, so the slot must exist first.
        while raw.size <= i
          raw.push("")
        end
        # Splice the RAW line; the rebuild's full reparse expands any tags in it,
        # exactly as a `set_content` of the same total text would.
        raw[i] = line
        rebuild_content_from_raw raw
      end

      def replace_base_line(i, line)
        fake = rtof_index(@child_base)
        replace_line(fake + i, line)
      end

      # Original ("fake") line *i*, as rendered (see `#rendered_content`).
      def line(i)
        # Empty content leaves `@wrapped_lines.fake` empty, where `i.clamp(0, fake.size - 1)`
        # clamps to `-1` (Crystal's two-arg clamp yields `max` even when `min > max`)
        # and `fake[-1]` would raise. A blank line matches Blessed's `getLine` for a
        # missing line.
        return "" if @wrapped_lines.fake.empty?
        i = i.clamp(0, @wrapped_lines.fake.size - 1)
        @wrapped_lines.fake[i]
      end

      # `#line`, but *i* counts from the current scroll base rather than from the
      # top of the content.
      def base_line(i)
        fake = rtof_index(@child_base)
        line(fake + i)
      end

      def clear_line(i)
        i = Math.min(i, @wrapped_lines.fake.size - 1)
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
        insert_line(@wrapped_lines.fake.size, line)
      end

      def remove_last_line(n)
        delete_line(@wrapped_lines.fake.size - 1, n)
      end

      # All original ("fake") lines, as rendered. A copy; mutating it does not
      # touch the widget.
      def lines
        @wrapped_lines.fake.dup
      end

      # All *wrapped* ("real") lines — one entry per screen row rather than per
      # original line. A copy; see `#lines` for the unwrapped view.
      def screen_lines
        @wrapped_lines.dup
      end
    end
  end
end
