module Crysterm
  class Window
    # Drawing (displaying rendered state on screen).
    #
    # "Rendering" fills an (Y,X) array of cells in memory with the desired
    # attributes and character (a framebuffer for the console). "Drawing" then
    # diffs the current vs. desired screen state and emits the text + escape
    # sequences needed to make the terminal match the in-memory picture in as few
    # sequences as possible.

    # Any prefix we want the final buffer to have
    @_buf = IO::Memory.new

    # Final buffer of data to print to screen. Contains content and escape sequences
    # needed to make the screen look like desired by user.
    @main : IO::Memory = IO::Memory.new 10_240 * 10

    # Temporary buffer for content and escape sequences for each individual row.
    @outbuf : IO::Memory = IO::Memory.new 10_240

    # Even more temporary buffer, for parts of a row and the short escape bursts
    # of line insert/delete ops. Cleared by `divert` before use, so it's shared
    # across these non-overlapping uses instead of allocating throwaways.
    @tmpbuf : IO::Memory = IO::Memory.new 64

    # From rendering:
    # @lines - Grid of desired cell contents in memory, the "framebuffer"

    property _ci = -1

    # Position where an artificial cursor was painted on the previous `draw`, or
    # `-1` when none. When the cursor moves rows (or stops), the vacated cell
    # must be repaired — see the repair note in `#draw`.
    @_acur_x = -1
    @_acur_y = -1

    @pre = IO::Memory.new 1024
    @post = IO::Memory.new 1024

    # Terminal control values used by the per-frame `#draw`. Derived from the
    # connected terminal (terminfo + features) and constant for the screen's
    # lifetime, so computed **once** here rather than per frame/cell. The static
    # parameter-free sequences (`smacs`/`rmacs`/`el`) are captured (`dup`'d off
    # terminfo's memory) for writing straight into the frame buffer. The
    # parameterized hot-path sequences (`cup`/`cuf`/SGR) are emitted as direct
    # ANSI at their call sites (terminfo `run` allocates a `Bytes` per call),
    # gated on `ansi_cursor` so a non-conforming terminal falls back to the safe
    # tput path. The `DrawCaps` record and `#compute_draw_caps` live on the
    # device `Window`; read here via the delegated `#draw_caps`.

    # Bytes the previous `draw` wrote to the terminal (`@pre`+`@main`+`@post`).
    # Read by `_render` for `Widget::Fps` throughput. Zero on an unchanged frame.
    getter last_draw_bytes : Int32 = 0

    # Cumulative bytes ever written by `draw` (only grows), for a `Widget::Fps`
    # total-traffic display.
    getter bytes_written : UInt64 = 0_u64

    # Routes Tput's escape-sequence output into `buf` for the block's duration
    # (Tput appends to `tput.ret` when set), then copies it into `dest` and
    # clears `tput.ret`. The block is yielded `buf` so it can also write directly
    # (e.g. raw newlines). The reset lives in an `ensure`, so a raising block
    # can't leave output permanently diverted; `dest` is written only on success.
    private def divert(buf : IO::Memory, dest : IO, & : IO::Memory ->) : Nil
      # Clear here so the buffer can be safely reused across calls (callers used
      # to either pass a throwaway `IO::Memory.new` or clear it themselves).
      buf.clear
      tput.ret = buf
      begin
        yield buf
        dest.write buf.to_slice
      ensure
        tput.ret = nil
      end
    end

    # Whether to bracket each painted frame in a DEC 2026 *synchronized update*
    # (`\e[?2026h` … `\e[?2026l`) so the terminal presents it atomically,
    # eliminating flicker/tearing on a multi-write redraw. Markers are emitted
    # only on frames that produce output (~14 bytes each), in the same write.
    # Harmless on unsupporting terminals (ignored, auto-release after a timeout).
    # Default from `Config.render_synchronized_output` (on).
    property? synchronized_output : Bool = Config.render_synchronized_output

    # Draws the screen based on the contents of in-memory grid of cells (`@lines`).
    def draw(start = 0, stop = @lines.size - 1)
      # D O:
      # emit Event::PreDraw

      @main.clear
      # No output produced yet this frame; updated below if a payload is written.
      @last_draw_bytes = 0
      # @outbuf.clear # Done below, for every line (`y`)
      lx = -1
      ly = -1
      acs = false

      # Terminal-constant capabilities (`@draw_caps`, via `#compute_draw_caps`),
      # derived once per `@tput` and bound to locals here. Only `bce_opt` and
      # `fu` — which can change at runtime — stay per-frame.
      caps = draw_caps
      has_bce = caps.has_bce
      parm_right_cursor = caps.parm_right_cursor
      alt_charset = caps.alt_charset
      broken_acs = caps.broken_acs
      acscr = caps.acscr
      term_unicode = caps.term_unicode
      u8 = caps.u8
      ncolors = caps.ncolors
      smacs = caps.smacs
      rmacs = caps.rmacs
      el = caps.el
      ansi_cursor = caps.ansi_cursor

      bce_opt = @optimization.bce?
      fu = full_unicode?
      # Whether the per-row scan may be bounded to the dirty-column range at all.
      # BCE's clear look-ahead reaches past the changed span and full_unicode's
      # wide-grapheme continuations straddle cell boundaries, so both force a
      # full-width scan. Constant for the frame.
      may_bound = !bce_opt && !fu

      if @_buf.size > 0
        @main.print @_buf
        @_buf.clear
      end

      ::Log.trace { "Drawing #{start}..#{stop}" }

      # The cursor that is actually drawn: the focused widget's own cursor if it
      # has one, else the screen default (see `Window#active_cursor`).
      c = active_cursor
      # The artificial-cursor predicate and target position are constant for the
      # whole draw, so hoist them out of the per-row/per-cell hot path.
      c_artificial = c.artificial?
      cursor_x = tput.cursor.x
      cursor_y = tput.cursor.y

      # Repair the cell a previously-painted artificial cursor left behind.
      # `draw` only scans dirty rows or the cursor's row, so when the cursor
      # moves to another row (or stops), the old row is otherwise untouched and
      # the cursor glyph in `@olines` would never be diffed away — a ghost cursor.
      # Mark the vacated cell dirty so the diff re-emits the real content. Staying
      # on the same cell needs no repair; a same-row move is covered by the full
      # scan the cursor's row gets.
      draw_acur = c_artificial && !c._hidden && (c._state != 0) && cursor_y >= start && cursor_y <= stop
      new_acur_x = draw_acur ? cursor_x : -1
      new_acur_y = draw_acur ? cursor_y : -1
      if @_acur_y >= 0 && (@_acur_x != new_acur_x || @_acur_y != new_acur_y)
        if (old_line = @lines[@_acur_y]?) && @_acur_x < old_line.size
          old_line.mark_dirty @_acur_x
        end
      end
      @_acur_x = new_acur_x
      @_acur_y = new_acur_y

      # For all rows (y = row coordinate)
      (start..stop).each do |y|
        # Current line we're looking at, which we'll possibly modify (array of cells)
        line = @lines[y]

        # Original line, as it was in the previous render
        o = @olines[y]

        # Cache the row width once; read by the per-cell loop bound and the BCE
        # scans below.
        line_size = line.size

        # Hoist the rows' backing arrays so the per-cell diff reads the
        # contiguous `Int64`/`Char` buffers directly via `unsafe_fetch`, instead
        # of `Indexable#[]` (bounds check plus a fresh `Cell` handle) per cell.
        # New-side reads are bounded by `line_size`, old-side by the `x < o_size`
        # guard below, so every `unsafe_fetch` is in range. Cells are mutated in
        # place (`unsafe_put`), so these references stay valid for the whole row.
        l_attrs = line.attrs
        l_chars = line.chars
        o_attrs = o.attrs
        o_chars = o.chars
        # Old-side width, hoisted so the diff bound-checks with `x < o_size`
        # instead of `o[x]?` (which builds a `Cell` handle just to test presence).
        o_size = o_attrs.size

        # Whether either side of this row carries a grapheme overlay, hoisted
        # once. When neither does (the overwhelming majority), the per-cell
        # `grapheme_at?` probes all compare nil==nil and are skipped wholesale.
        # `false` when full_unicode is off, collapsing the guards to a constant.
        l_has_g = fu && line.has_graphemes?
        o_has_g = fu && o.has_graphemes?
        any_g = l_has_g || o_has_g

        # ::Log.trace { line } if line.any? &.char.!=(' ')

        # Skip if no change in line
        if !line.dirty && !(c_artificial && (y == cursor_y))
          next
        end

        # Bound the per-cell scan to the columns that actually changed
        # (`[scan_lo, scan_hi]`), read before the dirty flag is cleared below.
        # Only on the common fast path: BCE, full_unicode, or an artificial
        # cursor on this row all force a full-width scan (see `may_bound`).
        scan_lo = 0
        scan_hi = line_size - 1
        if may_bound && !(c_artificial && y == cursor_y)
          dmin = line.dirty_min
          dmax = line.dirty_max
          scan_lo = dmin if dmin > scan_lo
          scan_hi = dmax if dmax < scan_hi
        end

        # We're processing this line, so mark it as not dirty now.
        line.dirty = false

        # Assume line is dirty by continuing:
        # XXX maybe need to optimize to draw only dirty parts, not the whole line?

        @outbuf.clear

        # Default attr code
        attr = @default_attr

        # When a wide grapheme is emitted it also covers the following
        # (continuation) cell, so that cell is skipped on the next iteration.
        skip_next = false

        # Highest column for which the BCE look-ahead is known to be pointless
        # (a previous scan proved the tail isn't a clearable run of spaces).
        # Avoids re-scanning a leading space run (otherwise O(width^2) on a
        # "spaces then content" line). Reset per row.
        bce_skip_until = -1

        # Column where an artificial cursor is painted on THIS row (or -1 when
        # none). The BCE clear-to-EOL look-ahead must NOT treat it as a clearable
        # blank: erasing a run reaching the cursor with `el` would break out of
        # the scan before the cursor cell is emitted, leaving it undrawn (the
        # cursor attr lives only in `desired_attr`, not the buffer the look-ahead
        # reads). `-1` in the common no-cursor case never matches a column.
        acur_col = (draw_acur && y == cursor_y) ? cursor_x : -1

        # When the scan starts past column 0, seed the skipped-run cursor exactly
        # as the full scan's leading run over [0, scan_lo) would: set `lx = 0,
        # ly = y` only if `lx` was -1 at row start; a leftover non-(-1) `lx` is
        # preserved (so the first changed cell repositions with an absolute `cup`,
        # matching the full scan). The row is prefixed with a cup to column 0 below.
        if scan_lo > 0 && lx == -1
          lx = 0
          ly = y
        end

        # For all cells in the changed span (x = column coordinate)
        scan_lo.upto(scan_hi) do |x|
          if skip_next
            skip_next = false
            next
          end

          # Desired attr code and char, read straight from the row's backing
          # arrays (see the hoist above).
          desired_attr = l_attrs.unsafe_fetch(x)
          desired_char = l_chars.unsafe_fetch(x)

          # Render the artificial cursor.
          if c_artificial && !c._hidden && (c._state != 0) && (x == cursor_x) && (y == cursor_y)
            desired_attr, tmpch = _artificial_cursor_attr(c, desired_attr)
            desired_char = tmpch if tmpch
            # XXX Is this needed:
          end

          # Take advantage of xterm's back_color_erase feature by using a
          # lookahead. Stop spitting out so many damn spaces. NOTE: Is checking
          # the bg for non BCE terminals worth the overhead?
          if bce_opt && (desired_char == ' ') && (x > bce_skip_until) &&
             (has_bce || (Attr.bg(desired_attr) == Attr.bg(@default_attr))) &&
             ((Attr.flags(desired_attr) & Attr::REVERSE) == (Attr.flags(@default_attr) & Attr::REVERSE))
            clr = true
            neq = false # Current line 'not equal' to line as it was on previous render (i.e. it changed content)
            breaker = line_size

            (x...line_size).each do |xx|
              lc_attr = l_attrs.unsafe_fetch(xx)
              lc_char = l_chars.unsafe_fetch(xx)

              # `line[xx] != {desired_attr, ' '}`: is this a clearable space? Read
              # from the hoisted arrays; under full_unicode a cell holding a
              # multi-codepoint cluster is never a bare space even if its base
              # codepoint is one, so the overlay must be nil.
              clearable = lc_attr == desired_attr && lc_char == ' '
              # The artificial-cursor cell is never clearable (see `acur_col`): the
              # cursor's reverse/glyph attribute lives only in the per-cell loop's
              # `desired_attr`, not in the buffer this look-ahead reads, so clearing
              # over it with `el` would drop the cursor for the frame.
              clearable = false if xx == acur_col
              # Only probe the overlay when this row actually has one; with none,
              # `grapheme_at?` is nil and `clearable &&= true` is a no-op.
              clearable &&= line.grapheme_at?(xx).nil? if l_has_g
              unless clearable
                clr = false
                breaker = xx
                break
              end

              # `line[xx] != o[xx]`: does this cell differ from what's on window?
              changed = lc_attr != o_attrs.unsafe_fetch(xx) || lc_char != o_chars.unsafe_fetch(xx)
              # With no overlay on either side both probes are nil, so the
              # comparison is nil != nil (false) — skip it.
              changed ||= line.grapheme_at?(xx) != o.grapheme_at?(xx) if any_g
              neq = true if changed
            end

            # If the tail wasn't clearable, the offending cell at `breaker` stays
            # in range for every column in (x, breaker), and the run (x, breaker)
            # shares `desired_attr`, so those scans would reach the same verdict.
            # Skip them. `breaker` itself may begin a new run (different attr), so
            # it is left scannable.
            bce_skip_until = breaker - 1 unless clr

            # Seems like this block performs clearing of a line, if it's not clear but needs to be
            if clr && neq
              lx = -1
              ly = -1
              if attr != desired_attr
                # Reset first when the terminal currently has any non-default
                # attribute active. `code2attr_to` writes the target attr from a
                # *blank* SGR state and emits NOTHING for the default attr (see
                # Screen.code2attr_to), so without this reset a transition to the
                # default attr (the common "colored content then a default-space
                # tail" line) would leave the previous cell's color/flags active:
                # the `el` below would then erase the rest of the line with that
                # stale background (BCE), and the leftover SGR would bleed into the
                # cells/rows drawn afterward. Mirrors the per-cell path's
                # `\e[m`-then-set sequence below.
                @outbuf.print "\e[m" if attr != @default_attr
                attr = desired_attr
                # Allocation-free SGR emission straight into the line buffer;
                # `code2attr` would allocate a fresh String for every cleared
                # line, every frame (see Screen.code2attr_to).
                Screen.code2attr_to(@outbuf, attr, ncolors)
              end

              # Clear to end of line at (x, y): a cursor move (see the reposition
              # note below) followed by the hoisted static `el`.
              if ansi_cursor
                @outbuf << "\e[" << (y + 1) << ';' << (x + 1) << 'H'
              else
                divert(@tmpbuf, @outbuf) { tput.cursor_position(y, x) }
              end
              @outbuf.write el

              (x...line_size).each do |xx|
                o[xx].attr = desired_attr
                o[xx].char = ' '
              end

              break
            end

            # D O:
            # If there's more than 10 spaces, use EL regardless
            # and start over drawing the rest of line. Might
            # not be worth it. Try to use ECH if the terminal
            # supports it. Maybe only try to use ECH here.
            # #if (tput.strings.erase_chars)
            # if (!clr && neq && (xx - x) > 10)
            #   lx = -1; ly = -1
            #   if (desired_attr != attr)
            #     @outbuf.print code2attr(desired_attr)
            #     attr = desired_attr
            #   end
            #   @outbuf.print tput.cup(y, x)
            #   if (tput.strings.erase_chars)
            #     # Use erase_chars to avoid erasing the whole line.
            #     @outbuf.print tput.ech(xx - x)
            #   else
            #     @outbuf.print tput.el()
            #   end
            #   if (tput.strings.parm_right_cursor)
            #     @outbuf.print tput.cuf(xx - x)
            #   else
            #     @outbuf.print tput.cup(y, xx)
            #   end
            #   fill_region(desired_attr, ' ', x, tput.strings.erase_chars ? xx : line.length, y, y + 1)
            #   x = xx - 1
            #   next
            # end
            # Skip to the next line if the rest of the line is already drawn.
            # if (!neq)
            #   for (; xx < line.length; xx++)
            #     if (line[xx][0] != o[xx][0] || line[xx][1] != o[xx][1])
            #       neq = true
            #       break
            #     end
            #   end
            #   if !neq
            #     attr = desired_attr
            #     break
            #   end
            # end
          end

          # Optimize by comparing the desired cell against what was last sent to
          # the terminal (`@olines`). A cell that is unchanged is skipped
          # entirely (nothing is emitted for it); `lx`/`ly` remember the start of
          # the skipped run so that when the next changed cell appears, a single
          # cursor move (cuf or cup) repositions over the run instead of redrawing
          # it.
          #
          # NOTE: the unchanged case must `next` the per-cell loop so the
          # emission code below is skipped. This therefore uses an explicit `if`
          # binding rather than `o[x]?.try do |ox| ... end`: inside a block,
          # `next` would only exit the block, after which the cell would still be
          # printed below — defeating the skip and desyncing the `cuf` run math
          # from the real cursor position.
          if x < o_size
            # Inlined, allocation-free cell diff, reading attr/char straight from
            # the backing arrays. In legacy mode a row never carries a grapheme
            # overlay, so the compare is just `attr == && char ==` and skipping the
            # `@graphemes` lookup is pure win on this per-cell hot path.
            #
            # Under `full_unicode` a cell's value also includes its grapheme
            # cluster, so we compare the new cell's overlay against the old one
            # (`ox == line[x]` semantics) — `desired_char` is only the cluster's
            # BASE codepoint, so without this a cell going from 'e' to a combining
            # 'e'+◌́ (same base, same attr) would be wrongly skipped and the mark
            # never emitted; conversely an unchanged cluster cell would be
            # needlessly re-emitted every frame. `grapheme_at?` is the same lookup
            # `Cell#grapheme_overlay` does, without constructing a `Cell`.
            #
            # The `legacy_cell_eq` flag still forces a miss for A/B benchmarking.
            # `unchanged` is declared here (not inside the macro `if`) so it stays
            # visible below.
            unchanged = false
            {% unless flag?(:legacy_cell_eq) %}
              unchanged = o_attrs.unsafe_fetch(x) == desired_attr && o_chars.unsafe_fetch(x) == desired_char
              # Skip the overlay compare when neither row has one (nil == nil is
              # true, leaving `unchanged` as-is).
              unchanged &&= o.grapheme_at?(x) == line.grapheme_at?(x) if any_g
            {% end %}
            if unchanged
              if lx == -1
                lx = x
                ly = y
              end
              next
            elsif lx != -1
              # Cursor reposition over the skipped (unchanged) run, emitted as
              # direct ANSI straight into the buffer rather than via terminfo.
              # These carry (x,y)/distance parameters and fire per run-break every
              # frame, so going through terminfo `run` would allocate a fresh
              # `Bytes` each call. `cuf` (`\e[<n>C`) and `cup` (`\e[<row>;<col>H`,
              # 1-based) are universal on every terminal Crysterm targets (it
              # already assumes ANSI SGR), so the hardcoded forms match terminfo's
              # output. Writing an `Int` to the IO emits its digits with no
              # `String` allocation.
              if !ansi_cursor
                # Non-conforming terminal: route through tput (captured into the
                # frame buffer via `divert`). Always an absolute move, since this
                # path can't assume `cuf` either.
                divert(@tmpbuf, @outbuf) { tput.cursor_position(y, x) }
              elsif parm_right_cursor && y == ly
                @outbuf << "\e[" << (x - lx) << 'C'
              else
                @outbuf << "\e[" << (y + 1) << ';' << (x + 1) << 'H'
              end
              lx = -1
              ly = -1
            end
            # Changed cell: build the old-side handle now (only here — not for
            # every unchanged cell, which is the common case) and write back what
            # is being emitted, so `@olines` mirrors the terminal. `x < o_size`
            # was already checked, so `unsafe_fetch` is the bounds-checked `o[x]`
            # without re-checking.
            ox = o.unsafe_fetch(x)
            ox.attr = desired_attr
            if fu && (g = line[x].grapheme_overlay)
              ox.grapheme = g
            else
              ox.char = desired_char
            end
          end

          if desired_attr != attr
            if attr != @default_attr
              @outbuf.print "\e[m"
            end
            if desired_attr != @default_attr
              @outbuf.print "\e["

              # Emit the SGR flags/colors via the shared helper (also used by
              # `Screen.code2attr_to`). If anything was written it ends in a ';',
              # which we back over and replace with the terminating 'm'. Note we
              # always emit "\e[" + "m" here (yielding a bare reset "\e[m" when
              # nothing was written) because reaching this branch means
              # `desired_attr != @default_attr`, which differs from
              # `code2attr_to`'s "emit nothing for the default attr" contract.
              if Screen.sgr_params_to(@outbuf, desired_attr, ncolors)
                @outbuf.seek -1, IO::Seek::Current
              end

              @outbuf.print 'm'
              # ::Log.trace { @outbuf.inspect }
            end
          end

          # TODO Enable this
          # # If we find a double-width char, eat the next character which should be
          # # a space due to parseContent's behavior.
          # if (@fullUnicode)
          #  # If this is a surrogate pair double-width char, we can ignore it
          #  # because parseContent already counted it as length=2.
          #  if (unicode.charWidth(line[x].char) == 2)
          #    # NOTE: At cols=44, the bug that is avoided
          #    # by the angles check occurs in widget-unicode:
          #    # Might also need: `line[x + 1].attr != line[x].attr`
          #    # for borderless boxes?
          #    if (x == line.length - 1 || angles[line[x + 1].char])
          #      # If we're at the end, we don't have enough space for a
          #      # double-width. Overwrite it with a space and ignore.
          #      desired_char = ' '
          #      o[x].char = '\0'
          #    else
          #      # ALWAYS refresh double-width chars because this special cursor
          #      # behavior is needed. There may be a more efficient way of doing
          #      # @ See above.
          #      o[x].char = '\0'
          #      # Eat the next character by moving forward and marking as a
          #      # space (which it is).
          #      o[++x].char = '\0'
          #    end
          #  end
          # end

          # Attempt to use ACS for supported characters.
          # This is not ideal, but it's how ncurses works.
          # There are a lot of terminals that support ACS
          # *and UTF8, but do not declare U8. So ACS ends
          # up being used (slower than utf8). Terminals
          # that do not support ACS and do not explicitly
          # support UTF8 get their unicode characters
          # replaced with really ugly ascii characters.
          # It is possible there is a terminal out there
          # somewhere that does not support ACS, but
          # supports UTF8, but I imagine it's unlikely.
          # Maybe remove !tput.unicode check, however,
          # this seems to be the way ncurses does it.
          #
          # Note the behavior of this IF/ELSE block. It may decide to
          # print to @outbuf certain prefix data, but after the IF/ELSE block
          # the 'ch' is always written. This logic is taken for speed. In the
          # case that the contents of the IF/ELSE block change in incompatible
          # way, this should be had in mind.
          # `acscr` is keyed only by non-ASCII glyphs in the `!broken_acs` case
          # used here (its lowest key is U+00A3), so probe the hash only for
          # non-ASCII cells — ASCII text and spaces, the vast majority, skip it
          # entirely. The single result is reused below instead of re-looked-up.
          acs_char = (alt_charset && !broken_acs && desired_char > '~') ? acscr[desired_char]? : nil
          if alt_charset && !broken_acs && (acs_char || acs)
            # Fun fact: even if tput.brokenACS wasn't checked here,
            # the linux console would still work fine because the acs
            # table would fail the check of: tput.features.acscr[desired_char]
            if ac = acs_char
              if acs
                desired_char = ac
              else
                # This method of doing it (like blessed does it) is nasty
                # since char gets changed to string when sm/rm escape
                # sequence is added to it:
                # sm = String.new smacs
                # desired_char = sm + tput.features.acscr[desired_char]
                #
                # So instead of that, print smacs into outbuf (line buffer), and
                # just set char to the desired char, knowing that it will be
                # printed into outbuf at the end of the loop thanks to generic code.
                @outbuf.write smacs
                desired_char = ac
                acs = true
              end
            elsif acs
              # Same trick as above, not this:
              # rm = String.new rmacs
              # desired_char = rm + desired_char
              # But this:
              @outbuf.write rmacs
              acs = false
            end
          elsif desired_char > '~'
            # The terminal couldn't render this non-ASCII glyph via ACS (no ACS,
            # or it's broken, or the glyph has no ACS mapping). U8 is not
            # consistently correct: some terminals that don't declare it actually
            # support utf8 (e.g. urxvt), but if a terminal declares neither ACS nor
            # U8, chances are it doesn't support UTF8 either, so reducing to ASCII
            # is the "safest" choice (fixes things like sun-color). It could also
            # be that $LANG is all that matters in some cases.
            if !term_unicode && (u8 != 1)
              # Reduction of ACS into ASCII chars.
              desired_char = Tput::ACSC::Data[desired_char]?.try(&.[2]) || '?'
            end
          end

          # Now print the cell's content. Under full_unicode: a continuation
          # cell (the trailing half of a wide grapheme) emits nothing — the wide
          # glyph already advanced the cursor; a cluster cell emits its whole
          # grapheme; and a wide cell claims its continuation cell, which the
          # next iteration skips (keeping cell index == terminal column).
          if fu
            current = line[x]
            unless current.continuation?
              # Fetch the grapheme overlay once and reuse it for both the emit
              # and the width below, instead of letting `current.width` repeat
              # the `@graphemes` lookup `grapheme_overlay` already did.
              g = current.grapheme_overlay
              if g
                @outbuf.print g
              else
                @outbuf.print desired_char
              end
              # Equivalent to `current.width` here: the continuation case is
              # excluded by the `unless` above, so width comes from the overlay
              # cluster if present, else from the cell's own codepoint (NOT
              # `desired_char`, which may have been ACS-reduced for output).
              w = g ? ::Crysterm::Unicode.width(g) : ::Crysterm::Unicode.width(current.char)
              if w == 2 && (oc = o[x + 1]?)
                oc.attr = desired_attr
                oc.continuation!
                skip_next = true
              end
            end
          else
            @outbuf.print desired_char
          end

          attr = desired_attr
        end

        # Reproduce the cursor-run state a full scan would leave: it would walk
        # the trailing unchanged cells (scan_hi, line_size) and, having reset `lx`
        # at the last changed cell, record the start of that trailing run. Mirror
        # it so the *next* row's reposition math is byte-identical to the full
        # scan. (No-op on the full-scan path, where scan_hi == line_size - 1.)
        if scan_hi < line_size - 1 && lx == -1
          lx = scan_hi + 1
          ly = y
        end

        if attr != @default_attr
          @outbuf.print "\e[m"
        end

        unless @outbuf.empty?
          # STDERR.puts @outbuf.size
          # Line-start cursor position (see the reposition note above):
          # `cup(y, 0)` == `\e[<row>;1H` (1-based), gated on `ansi_cursor`.
          if ansi_cursor
            @main << "\e[" << (y + 1) << ";1H"
          else
            divert(@tmpbuf, @main) { tput.cursor_position(y, 0) }
          end
          @main.write @outbuf.to_slice
        end
      end

      if acs
        @main.write rmacs
        acs = false
      end

      unless @main.size == 0
        @pre.clear
        @post.clear
        hidden = tput.cursor_hidden?

        # Hide the *hardware* cursor for the duration of this multi-write frame so
        # the real terminal cursor doesn't streak across the screen as the cell
        # runs (each prefixed by a `cup`) are emitted, then restore it afterward.
        # This MUST go straight to `tput` (not `Window#hide_cursor`/`#show_cursor`):
        # those dispatch on the *active* cursor and, when it is artificial, take
        # the artificial branch — which writes no escape (so the hardware cursor is
        # left visible and streaks anyway) and calls `render_if_active`, scheduling
        # a redundant render from *inside* `draw`. For a hardware cursor the
        # delegating form was byte-identical to this; for an artificial one it was
        # wrong on both counts. The captured sequences land in `@pre`/`@post`.
        divert(@tmpbuf, @pre) do
          tput.save_cursor
          tput.hide_cursor unless hidden
        end

        divert(@tmpbuf, @post) do
          tput.restore_cursor
          tput.show_cursor unless hidden
        end

        # D O:
        # display.flush()
        # display._owrite(@pre + @main + @post)
        #
        # Bracket the frame in a DEC 2026 synchronized update (when enabled) so
        # the terminal presents it atomically. Inlined into this single `_print`
        # — rather than separate begin/end calls — so the markers and the frame
        # land in one buffered write, with no markers emitted on empty frames.
        tput._print do |io|
          io << "\e[?2026h" if synchronized_output?
          io.write @pre.to_slice
          io.write @main.to_slice
          io.write @post.to_slice
          io << "\e[?2026l" if synchronized_output?
        end

        # Account for the bytes just emitted. `@_buf`'s buffered insert/delete-line
        # output is already folded into `@main` above, so the three buffers cover
        # everything `draw` sends this frame.
        @last_draw_bytes = @pre.size + @main.size + @post.size
        @bytes_written += @last_draw_bytes
      end

      # D O:
      # emit Event::Draw
    end

    def blank_line(ch = ' ', dirty = false)
      # `Row.new awidth` only reserves capacity (size 0); the row must actually
      # be populated with `awidth` cells, otherwise the blank lines inserted by
      # `insert_line`/`delete_line` are zero-width and render as nothing (and
      # later writes to `lines[y][x]` fall out of range). Mirrors how the main
      # screen buffer fills rows via `adjust_width`.
      o = Row.new awidth
      awidth.times { o.push @default_attr, ch }
      o.dirty = dirty
      o
    end

    # Shifts the cell buffer (`@lines`/`@olines`) *down* by `n` rows: a blank
    # line appears at `y` and the line that was at `bottom` falls off. This is
    # the buffer-side counterpart of the terminal `il`/scroll-down emitted by
    # `insert_line`/`insert_line_nc`.
    private def shift_lines_down(n, y, bottom)
      shift_lines n, insert_at: y, delete_at: bottom + 1
    end

    # Shifts the cell buffer (`@lines`/`@olines`) *up* by `n` rows: the line at
    # `y` is removed and a blank line appears at `bottom`. This is the
    # buffer-side counterpart of the terminal `dl`/scroll-up emitted by
    # `delete_line`/`delete_line_nc`.
    private def shift_lines_up(n, y, bottom)
      shift_lines n, insert_at: bottom + 1, delete_at: y
    end

    # Shared body of `shift_lines_down`/`shift_lines_up`: shifts both cell buffers
    # `n` times by inserting a fresh blank line at `insert_at` and dropping the
    # line at `delete_at`. The two directions differ only in which of the two
    # indices is the insert and which is the delete. A fresh `blank_line` per
    # buffer (never a shared row) so `@lines`/`@olines` stay independent.
    private def shift_lines(n, insert_at, delete_at)
      n.times do
        @lines.insert insert_at, blank_line
        @lines.delete_at delete_at
        @olines.insert insert_at, blank_line
        @olines.delete_at delete_at
      end
    end

    # Shared scaffold for the `insert_line`/`delete_line` family: verifies the
    # terminfo capabilities they need (always change-scroll-region + delete-line;
    # plus insert-line when *need_insert_line*), then runs *block* with output
    # diverted to `@_buf` and the scroll region temporarily set to `top..bottom`,
    # restoring it to the full screen afterwards. Returns `true` when the block
    # ran, `false` when a missing capability made it a no-op — so a caller does
    # `return unless with_scroll_region(...)` and only shifts its buffer then.
    private def with_scroll_region(top, bottom, need_insert_line = false, & : IO::Memory ->) : Bool
      if !tput.has?(&.change_scroll_region?) ||
         !tput.has?(&.delete_line?) ||
         (need_insert_line && !tput.has?(&.insert_line?))
        STDERR.puts "Missing needed terminfo capabilities"
        return false
      end

      divert(@tmpbuf, @_buf) do |buf|
        tput.set_scroll_region(top, bottom)
        yield buf
        tput.set_scroll_region(0, aheight - 1)
      end
      true
    end

    # Inserts lines into the screen. (If CSR is used, it bypasses the output buffer.)
    def insert_line(n, y, top, bottom)
      # D O:
      # if (y == top)
      #  return insert_line_nc(n, y, top, bottom)
      # end

      return unless with_scroll_region(top, bottom, need_insert_line: true) do
                      tput.cup(y, 0)
                      tput.il(n)
                    end

      shift_lines_down n, y, bottom
    end

    # Inserts lines into the screen using ncurses-compatible method. (If CSR is used, it bypasses the output buffer.)
    #
    # This is how ncurses does it.
    # Scroll down (up cursor-wise).
    # This will only work for top line deletion as opposed to arbitrary lines.
    def insert_line_nc(n, y, top, bottom)
      return unless with_scroll_region(top, bottom) do
                      tput.cup(top, 0)
                      tput.dl(n)
                    end

      shift_lines_down n, y, bottom
    end

    # Deletes lines from the screen. (If CSR is used, it bypasses the output buffer.)
    def delete_line(n, y, top, bottom)
      # D O:
      # if (y == top)
      #   return delete_line_nc(n, y, top, bottom)
      # end

      # XXX temporarily diverts output
      return unless with_scroll_region(top, bottom, need_insert_line: true) do
                      tput.cup(y, 0)
                      tput.dl(n)
                    end

      shift_lines_up n, y, bottom
    end

    # Deletes lines from the screen using ncurses-compatible method. (If CSR is used, it bypasses the output buffer.)
    #
    # This is how ncurses does it.
    # Scroll down (up cursor-wise).
    # This will only work for top line deletion as opposed to arbitrary lines.
    def delete_line_nc(n, y, top, bottom)
      # XXX temporarily diverts output
      return unless with_scroll_region(top, bottom) do |ret|
                      tput.cup(bottom, 0)
                      ret.print "\n" * n
                    end

      shift_lines_up n, y, bottom
    end

    # Inserts line at bottom of screen.
    def insert_bottom(top, bottom)
      delete_line(1, top, top, bottom)
    end

    # Inserts line at top of screen.
    def insert_top(top, bottom)
      insert_line(1, top, top, bottom)
    end

    # Deletes line at bottom of screen.
    def delete_bottom(top, bottom)
      # `clear_region`/`fill_region` are half-open in `y` (`yi.upto(yl - 1)`), so
      # the far edge `yl` must be ONE PAST the row to clear. `bottom, bottom`
      # iterates zero rows — i.e. the method was a complete no-op and the bottom
      # row was never cleared. Pass `bottom + 1` so the single row `bottom` is
      # actually cleared. (A faithful port of the same off-by-one in blessed's
      # `deleteBottom`, whose `clearRegion` is likewise half-open.)
      clear_region(0, awidth, bottom, bottom + 1)
    end

    # Deletes line at top of screen.
    def delete_top(top, bottom)
      # Same as: insert_bottom(top, bottom)
      delete_line(1, top, top, bottom)
    end

    # Parse the sides of an element to determine
    # whether an element has uniform cells on
    # both sides. If it does, we can use CSR to
    # optimize scrolling on a scrollable element.
    # Not exactly sure how worthwhile this is.
    # This will cause a performance/cpu-usage hit,
    # but will it be less or greater than the
    # performance hit of slow-rendering scrollable
    # boxes with clean sides?
    def clean_sides(el)
      pos = el.lpos

      return false unless pos

      return pos._clean_sides unless pos._clean_sides.nil?

      if pos.xi <= 0 && pos.xl >= awidth
        return pos._clean_sides = true
      end

      if @optimization.fast_csr?
        return pos._clean_sides = false if pos.yi < 0 || pos.yl > aheight
        return pos._clean_sides = true if (awidth - (pos.xl - pos.xi)) < Config.render_csr_threshold
        return pos._clean_sides = false
      end

      return false unless @optimization.smart_csr?

      # D O:
      # The scrollbar can't update properly, and there's also a
      # chance that the scrollbar may get moved around senselessly.
      # NOTE: In practice, this doesn't seem to be the case.
      # if @scrollbar
      #  return pos._clean_sides = false
      # end
      # Doesn't matter if we're only a height of 1.
      # if ((pos.yl - el.ibottom) - (pos.yi + el.itop) <= 1)
      #   return pos._clean_sides = false
      # end

      yi = pos.yi + el.itop
      yl = pos.yl - el.ibottom

      return pos._clean_sides = false if pos.yi < 0 || pos.yl > aheight
      return pos._clean_sides = true if (pos.xi - 1) < 0 || pos.xl > awidth

      # Both the band of columns left of the element and the band to its right
      # must be uniform top-to-bottom for the sides to count as clean; the inner
      # column scan is identical for either band, so it lives in `column_uniform?`.
      (pos.xi - 1).downto(0) do |x|
        return pos._clean_sides = false unless column_uniform? x, yi, yl
      end

      (pos.xl...awidth).each do |x|
        return pos._clean_sides = false unless column_uniform? x, yi, yl
      end

      pos._clean_sides = true
    end

    # Whether column *x* of `@olines` holds the same cell on every row of
    # `yi...yl` (the uniformity test `clean_sides` runs on the columns flanking a
    # scrollable element). A row missing the column stops the scan early, exactly
    # as the original per-band loops did, and a missing top row (`@olines[yi]`)
    # leaves the reference cell nil so the scan breaks before any comparison.
    private def column_uniform?(x, yi, yl) : Bool
      first = @olines[yi][x] if @olines[yi]?
      yi.upto(yl - 1) do |y|
        break unless @olines[y]? && @olines[y][x]?
        ch = @olines[y][x]
        return false if ch != first
      end
      true
    end

    # Clears any chosen region on the screen.
    def clear_region(xi, xl, yi, yl, override = false)
      fill_region @default_attr, ' ', xi, xl, yi, yl, override
    end

    # Forces the cells in the given region to be re-emitted to the terminal on
    # the next `#draw`, even if their content is unchanged from the previous
    # frame.
    #
    # `#draw` diffs `@lines` (this frame) against `@olines` (what is on the
    # terminal) and skips cells that did not change. That is normally what we
    # want, but a widget drawing *outside* the cell model — e.g. a
    # `Widget::Media::Overlay`, whose w3m image is an overlay painted on top of the
    # terminal — needs the cells underneath a stale overlay to be physically
    # re-emitted so the terminal redraws text over it. Poisoning `@olines` here
    # makes the diff treat those cells as changed.
    def invalidate_region(xi, xl, yi, yl)
      # Damage tracking: this pokes `@olines` outside the cell model (a w3m image
      # overlay), which the selective path can't reason about — force the full
      # path for any frame that does it.
      note_effect

      xi = 0 if xi < 0
      yi = 0 if yi < 0

      yi.upto(yl - 1) do |y|
        oline = @olines[y]?
        break unless oline

        xi.upto(xl - 1) do |x|
          ocell = oline[x]?
          break unless ocell
          # A sentinel the real cell content can never equal, so `draw` re-emits.
          ocell.char = '\u{0}'
        end

        @lines[y]?.try(&.dirty=(true))
      end
    end

    # Walks every existing cell of the rectangular region `[xi, xl) × [yi, yl)`
    # in `@lines`, yielding each cell together with its line. A row's scan stops
    # at the first missing cell and the whole walk stops at the first missing
    # row, mirroring the `break` behavior of the original per-region loops. With
    # `clamp` (the default) a negative `xi`/`yi` origin is pulled back to 0; the
    # shadow/blend callers pass their bounds verbatim with `clamp: false`.
    #
    # A negative index is treated as off the top/left of the grid and SKIPPED
    # (the cell at column/row 0 onward is still visited). This must be explicit:
    # Crystal's `Array#[]?`/`Indexable#[]?` count a negative index *from the
    # end* (`@lines[-1]?` is the last row, not `nil`), so a `clamp: false`
    # caller passing a negative origin — exactly what a widget's top/left shadow
    # does when it sits against the top/left screen edge (`yi - s.top`,
    # `xi - s.left`) — would otherwise wrap around and blend the shadow band onto
    # rows/columns at the OPPOSITE (bottom/right) edge. Off the bottom/right
    # (index >= size) correctly yields `nil` and breaks.
    private def each_region_cell(xi, xl, yi, yl, clamp = true, &)
      if clamp
        xi = 0 if xi < 0
        yi = 0 if yi < 0
      end

      yi.upto(yl - 1) do |y|
        next if y < 0
        line = @lines[y]?
        break unless line

        xi.upto(xl - 1) do |x|
          next if x < 0
          cell = line[x]?
          break unless cell

          yield cell, line
        end
      end
    end

    # Fills any chosen region on the screen with chosen character and attributes.
    #
    # This is the per-frame full-screen clear path (`clear_region` in `_render`
    # runs it over the whole grid every frame), so unlike the shared
    # `each_region_cell` it hoists the row's backing arrays (`attrs`/`chars`) and
    # width once and indexes them with `unsafe_fetch`/`unsafe_put` — the same
    # array-hoist `draw` uses — instead of constructing a `Cell` handle and going
    # through a bounds-checked `line[x]?` per cell. `xi`/`yi` are clamped to >= 0
    # (matching `each_region_cell`'s clamp), and cells are contiguous, so a cell
    # is "missing" only when `x` runs past the row end (`xend`); every
    # `unsafe_*` is thus provably in range.
    def fill_region(attr, ch, xi, xl, yi, yl, override = false)
      xi = 0 if xi < 0
      yi = 0 if yi < 0

      yi.upto(yl - 1) do |y|
        line = @lines[y]?
        break unless line

        attrs = line.attrs
        chars = line.chars
        n = attrs.size
        xend = xl < n ? xl : n
        # Whether this row carries ANY grapheme overlay, hoisted once per row.
        # This is the per-frame full-screen clear path, and the overwhelming
        # majority of rows have no overlay — so skipping the per-cell
        # `grapheme_at?`/`delete_grapheme` calls (each a method call whose
        # overhead dominated the render profile) on those rows is a real win,
        # not just the nil-check the per-cell probe already was.
        has_g = line.has_graphemes?

        x = xi
        while x < xend
          # Equivalent to `cell != {attr, ch}` (see `Cell#==(Tuple)`): a cell
          # carrying a grapheme overlay is never equal to a single-char tuple, so
          # it must be rewritten. The `||` short-circuits exactly as `==` does;
          # the `grapheme_at?` probe is reached only when attr/char already match
          # AND the row has some overlay (`has_g`), so overlay-free rows never
          # call it.
          if override || attrs.unsafe_fetch(x) != attr || chars.unsafe_fetch(x) != ch || (has_g && !line.grapheme_at?(x).nil?)
            attrs.unsafe_put(x, attr)
            chars.unsafe_put(x, ch)
            # Mirrors `Cell#char=`, which drops any cluster overlay on the cell —
            # only needed when the row actually carries one.
            line.delete_grapheme(x) if has_g
            # Narrow the dirty range to this column so `draw` can bound its scan
            # (the per-frame clear typically changes only the few cells a widget
            # painted last frame).
            line.mark_dirty x
          end
          x += 1
        end
      end
    end

    # Alpha-blends every cell in a region toward black (shadow compositing): the
    # counterpart of `fill_region` for the `Widget` shadow passes, which all
    # share this exact `Colors.blend(cell.attr, alpha:)` loop and differ only in
    # bounds. Unlike `fill_region` this does NOT clamp `xi`/`yi` to 0 — the
    # shadow callers already pass the exact (sometimes intentionally unclamped)
    # bounds, and the `lines[y]?`/`line[x]?` lookups skip anything off the grid —
    # so the four call sites keep their precise original behavior.
    def blend_region(alpha, xi, xl, yi, yl)
      each_region_cell(xi, xl, yi, yl, clamp: false) do |cell, line|
        cell.attr = Colors.blend(cell.attr, alpha: alpha)
        line.dirty = true
      end
    end

    # Tints every cell in the region toward `color` by `alpha` (`0` = unchanged,
    # `1` = fully `color`) — the color overlay behind `style.tint`. Like
    # `#blend_region` but toward an arbitrary color instead of black.
    def tint_region(alpha, color, xi, xl, yi, yl)
      each_region_cell(xi, xl, yi, yl) do |cell, line|
        cell.attr = Colors.tint(cell.attr, color, alpha)
        line.dirty = true
      end
    end
  end
end
