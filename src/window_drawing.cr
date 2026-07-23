module Crysterm
  class Window
    # Drawing (displaying rendered state on screen).
    #
    # "Rendering" fills the in-memory (Y,X) cell grid with desired attributes and
    # characters. "Drawing" diffs current vs. desired state and emits the text +
    # escape sequences to match the terminal to it in as few sequences as possible.

    # Any prefix we want the final buffer to have
    @_buf = IO::Memory.new

    # Final buffer of data to print to screen: content + escape sequences.
    @main : IO::Memory = IO::Memory.new 10_240 * 10

    # Temporary buffer for content and escape sequences for each individual row.
    @outbuf : IO::Memory = IO::Memory.new 10_240

    # Scratch buffer for parts of a row and the short escape bursts of line
    # insert/delete ops. Cleared by `divert` before use, so these non-overlapping
    # uses share it.
    @tmpbuf : IO::Memory = IO::Memory.new 64

    # From rendering:
    # @lines - Grid of desired cell contents in memory, the "framebuffer"

    protected property render_index_cursor = -1

    # Position where an artificial cursor was painted on the previous `draw`, or
    # `-1` when none. The vacated cell needs repairing when the cursor moves rows
    # or stops.
    @_acur_x = -1
    @_acur_y = -1

    @pre = IO::Memory.new 1024
    @post = IO::Memory.new 1024

    # Set by `#draw` when it produced output (`@pre`+`@main`+`@post`) not yet
    # written to the terminal; consumed and cleared by `#flush_frame`.
    @_frame_pending = false

    # `DrawCaps` holds the terminal control values the per-frame `#draw` needs:
    # derived from terminfo + features, constant for the screen's lifetime, and so
    # computed once rather than per frame. Static sequences (`smacs`/`rmacs`/`el`)
    # are captured for writing straight into the frame buffer; parameterized
    # hot-path ones (`cup`/`cuf`/SGR) are emitted as direct ANSI at their call
    # sites, gated on `ansi_cursor` so a non-conforming terminal falls back to the
    # tput path.

    # Bytes the previous `draw` wrote to the terminal (`@pre`+`@main`+`@post`).
    # Zero on an unchanged frame.
    getter last_draw_bytes : Int32 = 0

    # Cumulative bytes ever written by `draw` (only grows).
    getter bytes_written : UInt64 = 0_u64

    # Routes Tput's escape-sequence output into `buf` for the block's duration
    # (Tput appends to `tput.ret` when set), then copies it into `dest`. The block
    # is yielded `buf` so it can also write directly (e.g. raw newlines). `dest` is
    # written only on success; the `ensure` keeps a raising block from leaving
    # output permanently diverted.
    private def divert(buf : IO::Memory, dest : IO, & : IO::Memory ->) : Nil
      buf.clear
      tput.ret = buf
      begin
        yield buf
        dest.write buf.to_slice
      ensure
        tput.ret = nil
      end
    end

    # Reduces a non-ASCII glyph to its ASCII fallback (index 2 of the ACSC table
    # entry), or `'?'` when the glyph has no ACS mapping.
    private def ascii_fallback(ch : Char) : Char
      Tput::ACSC::Data[ch]?.try(&.[2]) || '?'
    end

    # Emits a cursor move to (`y`, `x`) (0-based) into `dest`: direct ANSI
    # (`\e[<row>;<col>H`, 1-based) when `ansi_cursor`, else the terminfo path
    # via `#divert`.
    private def emit_cursor_position(dest : IO, ansi_cursor : Bool, y : Int, x : Int) : Nil
      # Inline mode slides the whole surface down to its anchor row; `0` (the
      # default) makes this a no-op in full-screen mode.
      y += render_row_offset
      if ansi_cursor
        dest << "\e[" << (y + 1) << ';' << (x + 1) << 'H'
      else
        divert(@tmpbuf, dest) { tput.cursor_position(y, x) }
      end
    end

    # Whether to bracket each painted frame in a DEC 2026 *synchronized update*
    # (`\e[?2026h` … `\e[?2026l`) so the terminal presents it atomically,
    # eliminating flicker/tearing on a multi-write redraw. Harmless on
    # unsupporting terminals (ignored, auto-release after a timeout). Defaults to
    # `Config.render_synchronized_output`.
    property? synchronized_output : Bool = Config.render_synchronized_output

    # Whether cells carrying a hyperlink id draw with OSC 8 hyperlink escapes
    # (`\e]8;;URI\e\\` … `\e]8;;\e\\`), making anchors clickable on supporting
    # terminals. When off, `#link_id` registers nothing, so no cell ever carries a
    # link. Defaults to `Config.render_hyperlinks`.
    property? hyperlinks : Bool = Config.render_hyperlinks

    # OSC 8 hyperlink registry: cells store a compact `UInt16` id; the URIs live
    # here, deduplicated. Id `0` is "no link".
    @link_urls = [] of String
    @link_ids = {} of String => UInt16

    # Registers *url* and returns its cell link id — the value to assign to
    # `Cell#link=` for every cell the link covers. Returns `0` (no link) for an
    # empty URL, when `#hyperlinks?` is off, or if the registry is full. URLs are
    # stripped of control characters and length-capped, since they travel inside
    # an escape sequence.
    def link_id(url : String) : UInt16
      return 0_u16 if url.empty? || !hyperlinks?
      @link_ids[url]? || begin
        return 0_u16 if @link_urls.size >= 0xFFFF
        clean = url.gsub(/[\x00-\x1f\x7f]/, "")
        clean = clean[0, 2048] if clean.size > 2048
        @link_urls << clean
        @link_ids[url] = @link_urls.size.to_u16
      end
    end

    # The URI registered under cell link id *id*, or nil (id 0 or unknown).
    def link_url(id : UInt16) : String?
      return if id == 0
      @link_urls[id - 1]?
    end

    # Emits the OSC 8 sequence switching the terminal's "current hyperlink" to
    # *id*'s URI (`0` = close): printed cells from here on carry the link.
    private def emit_link(dest : IO, id : UInt16) : Nil
      divert(@tmpbuf, dest) do
        if url = link_url(id)
          tput.begin_hyperlink url
        else
          tput.end_hyperlink
        end
      end
    end

    # Draws the screen based on the contents of in-memory grid of cells (`@lines`).
    #
    # Diffs `@lines` against `@flushed_lines` and encodes the needed escapes into the
    # frame buffers (`@pre`/`@main`/`@post`), then — unless *flush* is false —
    # writes them to the terminal via `#flush_frame`. `#repaint` passes
    # `flush: false` so it can time the diff/encode and the (blocking) terminal
    # write separately.
    protected def draw(start = 0, stop = @lines.size - 1, flush = true)
      @main.clear
      @last_draw_bytes = 0
      lx = -1
      ly = -1
      acs = false
      # OSC 8 hyperlink currently in effect on the terminal (0 = none). The frame
      # closes it before finishing, so every frame starts link-free.
      cur_link = 0_u16

      # Terminal-constant capabilities bound to locals. Only `bce_opt`, `fu` and
      # `ncolors` can change at runtime, so they stay per-frame.
      caps = draw_caps
      has_bce = caps.has_bce
      parm_right_cursor = caps.parm_right_cursor
      alt_charset = caps.alt_charset
      broken_acs = caps.broken_acs
      acscr = caps.acscr
      term_unicode = caps.term_unicode
      u8 = caps.u8
      smacs = caps.smacs
      rmacs = caps.rmacs
      el = caps.el
      ansi_cursor = caps.ansi_cursor

      bce_opt = @optimization.bce?
      # The bg/deco fields the BCE look-ahead gate compares against; `@default_attr`
      # is constant for the whole call.
      default_bg = Attr.bg(@default_attr)
      default_deco = Attr.flags(@default_attr) & (Attr::REVERSE | Attr::UNDERLINE | Attr::STRIKE)
      fu = full_unicode_effective?
      # Output color depth used to reduce SGR colors. NOT the frozen
      # `caps.ncolors`: `#color_count` re-resolves the `colors.depth` config/env
      # override, so a depth changed at runtime reaches the wire.
      ncolors = color_count
      # Whether non-ASCII glyphs must be reduced to a 1-column ASCII fallback.
      ascii_reduce = !term_unicode && (u8 != 1)
      # Whether the per-row scan may be bounded to the dirty-column range. BCE's
      # clear look-ahead reaches past the changed span and full_unicode's
      # wide-grapheme continuations straddle cell boundaries, so both force a
      # full-width scan.
      may_bound = !bce_opt && !fu

      if @_buf.size > 0
        @main.print @_buf
        @_buf.clear
      end

      ::Log.trace { "Drawing #{start}..#{stop}" }

      # The cursor that is actually drawn: the focused widget's own cursor if it
      # has one, else the screen default.
      c = active_cursor
      c_artificial = c.artificial?
      cursor_x = tput.cursor.x
      # The tracker holds the PHYSICAL row (every positioning path adds
      # `render_row_offset` before `cup`) while this method compares against
      # surface rows, so translate back. May go negative when the cursor sits
      # above an inline region, which correctly fails the `>= start` guard below.
      cursor_y = tput.cursor.y - render_row_offset

      # Repair the cell a previously-painted artificial cursor left behind: `draw`
      # only scans dirty rows or the cursor's row, so a cursor moving to another
      # row (or stopping) would leave its glyph in `@flushed_lines` never diffed away.
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
        o = @flushed_lines[y]

        # Skip if no change in line. Checked BEFORE the row hoists below, so a
        # skipped row does none of that work.
        if !line.dirty && !(c_artificial && (y == cursor_y))
          next
        end

        line_size = line.size

        # Hoist the rows' backing arrays so the per-cell diff reads the contiguous
        # buffers via `unsafe_fetch` instead of building a `Cell` handle per cell.
        # New-side reads are bounded by `line_size`, old-side by the `x < o_size`
        # guard below, so every `unsafe_fetch` is in range. Cells are mutated in
        # place, so these references stay valid for the whole row.
        l_attrs = line.attrs
        l_chars = line.chars
        o_attrs = o.attrs
        o_chars = o.chars
        o_size = o_attrs.size

        # Whether either side of this row carries a grapheme overlay: when neither
        # does (the common case), every per-cell `grapheme_at?` probe compares
        # nil==nil and is skipped wholesale.
        l_has_g = fu && line.has_graphemes?
        o_has_g = fu && o.has_graphemes?
        any_g = l_has_g || o_has_g

        # Same hoist for the hyperlink overlays.
        l_has_l = line.has_links?
        o_has_l = o.has_links?
        any_l = l_has_l || o_has_l

        # Bound the per-cell scan to the columns that actually changed, read before
        # the dirty flag is cleared below. Only on the common fast path — BCE,
        # full_unicode, or an artificial cursor on this row force a full-width scan.
        scan_lo = 0
        scan_hi = line_size - 1
        if may_bound && !(c_artificial && y == cursor_y)
          dmin = line.dirty_min
          dmax = line.dirty_max
          scan_lo = dmin if dmin > scan_lo
          scan_hi = dmax if dmax < scan_hi
        end

        line.dirty = false

        @outbuf.clear

        attr = @default_attr

        # When a wide grapheme is emitted it also covers the following
        # (continuation) cell, so that cell is skipped on the next iteration.
        skip_next = false

        # Highest column for which the BCE look-ahead is known to be pointless (a
        # previous scan proved the tail isn't a clearable run of spaces). Keeps a
        # "spaces then content" line from re-scanning its leading run, O(width^2).
        bce_skip_until = -1

        # Column where an artificial cursor is painted on THIS row (or -1). The BCE
        # clear-to-EOL look-ahead must NOT treat it as a clearable blank: erasing a
        # run reaching the cursor with `el` would break out of the scan before the
        # cursor cell is emitted, leaving it undrawn (the cursor attr lives only in
        # `desired_attr`, not the buffer the look-ahead reads).
        acur_col = (draw_acur && y == cursor_y) ? cursor_x : -1

        # When the scan starts past column 0, seed the skipped-run cursor as the
        # full scan's leading run over [0, scan_lo) would. A leftover non-(-1) `lx`
        # is preserved, so the first changed cell repositions with an absolute
        # `cup`, matching the full scan.
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

          desired_attr = l_attrs.unsafe_fetch(x)
          desired_char = l_chars.unsafe_fetch(x)

          # Render the artificial cursor. `acur_col` already encodes the whole
          # per-row condition (or -1), so this is one compare per cell.
          #
          # `acur_glyph` records whether the cursor *replaced* this cell's glyph
          # with its own: the line and custom (`none`) shapes return a char, while
          # block/underline return nil and change only the attribute. A replacing
          # cursor's glyph must win over any grapheme-cluster overlay the cell
          # carries, or the `fu` emit path re-reads the overlay and the cursor is
          # never shown.
          acur_glyph = false
          if x == acur_col
            desired_attr, tmpch = _artificial_cursor_attr(c, desired_attr)
            if tmpch
              desired_char = tmpch
              acur_glyph = true
            end
          end

          # Take advantage of xterm's back_color_erase via a lookahead, to avoid
          # emitting runs of spaces.
          #
          # The flag-parity gate must cover every attribute that visibly decorates
          # a printed *space*: `el` fills with the background only, so a run of
          # UNDERLINE/STRIKE (not just REVERSE) blanks would come out undecorated
          # and — `@flushed_lines` being mirrored as-drawn — stay missing forever.
          if bce_opt && (desired_char == ' ') && (x > bce_skip_until) &&
             (has_bce || (Attr.bg(desired_attr) == default_bg)) &&
             ((Attr.flags(desired_attr) & (Attr::REVERSE | Attr::UNDERLINE | Attr::STRIKE)) == default_deco)
            clr = true
            neq = false # line changed content vs. previous render
            breaker = line_size

            (x...line_size).each do |xx|
              lc_attr = l_attrs.unsafe_fetch(xx)
              lc_char = l_chars.unsafe_fetch(xx)

              # `line[xx] != {desired_attr, ' '}`: is this a clearable space? Under
              # full_unicode a cell holding a multi-codepoint cluster is never a
              # bare space even if its base codepoint is one, so the overlay must
              # be nil.
              clearable = lc_attr == desired_attr && lc_char == ' '
              # The artificial-cursor cell is never clearable.
              clearable = false if xx == acur_col
              clearable &&= line.grapheme_at?(xx).nil? if l_has_g
              # A hyperlinked cell can't be erased — `el` prints nothing, so the
              # link would be lost.
              clearable &&= line.link_at(xx) == 0_u16 if l_has_l
              unless clearable
                clr = false
                breaker = xx
                break
              end

              # `line[xx] != o[xx]`: does this cell differ from what's on window?
              changed = lc_attr != o_attrs.unsafe_fetch(xx) || lc_char != o_chars.unsafe_fetch(xx)
              changed ||= line.grapheme_at?(xx) != o.grapheme_at?(xx) if any_g
              changed ||= line.link_at(xx) != o.link_at(xx) if any_l
              neq = true if changed
            end

            # If the tail wasn't clearable, every column in (x, breaker) shares
            # `desired_attr` and still sees the offending cell at `breaker`, so
            # those scans reach the same verdict — skip them. `breaker` itself may
            # begin a new run, so it stays scannable.
            bce_skip_until = breaker - 1 unless clr

            # Clear the line if it's not clear but needs to be.
            if clr && neq
              lx = -1
              ly = -1
              # `el` prints nothing, but close any open hyperlink so it can't
              # bleed into whatever is emitted next.
              if cur_link != 0_u16
                emit_link(@outbuf, 0_u16)
                cur_link = 0_u16
              end
              if attr != desired_attr
                # Reset first when any non-default attribute is active:
                # `Screen.write_sgr` writes the target attr from a *blank* SGR
                # state and emits nothing for the default attr, so without this the
                # `el` below would erase the line with a stale background (BCE) and
                # the leftover SGR would bleed into later cells/rows.
                @outbuf.print "\e[m" if attr != @default_attr
                attr = desired_attr
                # Allocation-free SGR emission straight into the line buffer.
                Screen.write_sgr(@outbuf, attr, ncolors)
              end

              # Clear to end of line at (x, y).
              emit_cursor_position(@outbuf, ansi_cursor, y, x)
              @outbuf.write el

              # Mirror the cleared run into `@flushed_lines` through the hoisted backing
              # arrays. Overlay cleanup is needed only when the old row carries one;
              # writes never install one at >= x mid-row, so `o_has_g` still decides.
              o_stop = line_size < o_size ? line_size : o_size
              (x...o_stop).each do |xx|
                o_attrs.unsafe_put(xx, desired_attr)
                o_chars.unsafe_put(xx, ' ')
              end
              if o_has_g
                (x...o_stop).each { |xx| o.delete_grapheme xx }
              end
              if o_has_l
                (x...o_stop).each { |xx| o.delete_link xx }
              end

              break
            end
          end

          # Optimize by comparing the desired cell against what was last sent to
          # the terminal (`@flushed_lines`). An unchanged cell is skipped entirely;
          # `lx`/`ly` remember the start of the skipped run so the next changed
          # cell repositions over it with a single cursor move (cuf or cup)
          # instead of redrawing it.
          #
          # NOTE: the unchanged case must `next` the per-cell loop, so this is an
          # explicit `if` binding rather than `o[x]?.try do |ox| ... end`: inside a
          # block `next` would only exit the block, and the cell would still be
          # printed below — desyncing the `cuf` run math from the real cursor.
          if x < o_size
            # Inlined, allocation-free cell diff. In legacy mode a row never carries
            # a grapheme overlay, so the compare is just attr + char.
            #
            # Under `full_unicode` a cell's value also includes its grapheme
            # cluster, so the overlays are compared too: `desired_char` is only the
            # cluster's BASE codepoint, so a cell going from 'e' to 'e'+◌́ (same
            # base, same attr) would otherwise be wrongly skipped, and an unchanged
            # cluster cell needlessly re-emitted every frame.
            #
            # `legacy_cell_eq` forces a miss for A/B benchmarking. `unchanged` is
            # declared outside the macro `if` so it stays visible below.
            unchanged = false
            {% unless flag?(:legacy_cell_eq) %}
              unchanged = o_attrs.unsafe_fetch(x) == desired_attr && o_chars.unsafe_fetch(x) == desired_char
              unchanged &&= o.grapheme_at?(x) == line.grapheme_at?(x) if any_g
              # A link-only change (same glyph/attr, different target) still
              # re-emits the cell so the terminal updates the hyperlink.
              unchanged &&= o.link_at(x) == line.link_at(x) if any_l
            {% end %}
            if unchanged
              if lx == -1
                lx = x
                ly = y
              end
              next
            elsif lx != -1
              # Cursor reposition over the skipped (unchanged) run, emitted as
              # direct ANSI rather than via terminfo (whose `run` would allocate a
              # `Bytes` per run-break, every frame). `cuf` (`\e[<n>C`) and `cup`
              # (`\e[<row>;<col>H`, 1-based) are universal on every terminal
              # Crysterm targets, which already assumes ANSI SGR.
              if ansi_cursor && parm_right_cursor && y == ly
                @outbuf << "\e[" << (x - lx) << 'C'
              else
                # Non-conforming terminal: route through tput. Always an absolute
                # move, since this path can't assume `cuf` either.
                emit_cursor_position(@outbuf, ansi_cursor, y, x)
              end
              lx = -1
              ly = -1
            end
            # Changed cell: build the old-side handle now — not for every unchanged
            # cell, the common case — and write back what is being emitted, so
            # `@flushed_lines` mirrors the terminal. `x < o_size` was already checked.
            ox = o.unsafe_fetch(x)
            ox.attr = desired_attr
            if fu && l_has_g && !acur_glyph && (g = line.grapheme_at?(x))
              ox.grapheme = g
            else
              ox.char = desired_char
            end
            # Mirror the link too. The content writes above just cleared the old
            # side's link, so only a present link needs storing.
            if l_has_l && (lid = line.link_at(x)) != 0_u16
              o.set_link(x, lid)
            end
          end

          if desired_attr != attr
            if attr != @default_attr
              @outbuf.print "\e[m"
            end
            if desired_attr != @default_attr
              @outbuf.print "\e["

              # `sgr_params_to` ends in a ';' if it wrote anything; back over it and
              # replace it with the terminating 'm'. The "\e[" + "m" is emitted
              # unconditionally (a bare reset when nothing was written) — unlike
              # `write_sgr`, this branch is only reached for a non-default attr.
              if Screen.sgr_params_to(@outbuf, desired_attr, ncolors)
                @outbuf.seek -1, IO::Seek::Current
              end

              @outbuf.print 'm'
              # ::Log.trace { @outbuf.inspect }
            end
          end

          # Switch the terminal's "current hyperlink" (OSC 8) when this printed
          # cell's link id differs from the one in effect.
          if l_has_l || cur_link != 0_u16
            lid = l_has_l ? line.link_at(x) : 0_u16
            if lid != cur_link
              emit_link(@outbuf, lid)
              cur_link = lid
            end
          end

          # Attempt to use ACS for supported characters. Not ideal, but it's how
          # ncurses works: many terminals support both ACS and UTF8 but don't
          # declare U8, so ACS ends up used (slower than utf8); terminals
          # supporting neither get unicode chars replaced with ascii fallbacks.
          #
          # This IF/ELSE block may print a prefix to @outbuf, but 'ch' is always
          # written after it regardless — keep that in mind if changing the logic.
          # In the `!broken_acs` case used here `acscr`'s lowest key is U+00A3, so
          # only non-ASCII cells need probe the hash.
          acs_char = (alt_charset && !broken_acs && desired_char > '~') ? acscr[desired_char]? : nil
          if alt_charset && !broken_acs && (acs_char || acs)
            # Even without checking tput.brokenACS, the linux console would still
            # work fine since its acs table fails tput.features.acscr[desired_char].
            if ac = acs_char
              if acs
                desired_char = ac
              else
                # smacs goes straight into outbuf rather than being prepended to a
                # per-cell String; the char itself prints at the end of the loop.
                @outbuf.write smacs
                desired_char = ac
                acs = true
              end
            elsif acs
              @outbuf.write rmacs
              acs = false
            end
          elsif desired_char > '~'
            # The terminal couldn't render this non-ASCII glyph via ACS (no ACS, or
            # it's broken, or the glyph has no ACS mapping). U8 isn't always
            # reliable (urxvt and others support utf8 undeclared), but a terminal
            # declaring neither ACS nor U8 likely has no UTF8 either, so reducing to
            # ASCII is safest (fixes sun-color and the like).
            if ascii_reduce
              desired_char = ascii_fallback(desired_char)
            end
          end

          # Print the cell's content. Under full_unicode: a continuation cell
          # (trailing half of a wide grapheme) emits nothing — the wide glyph
          # already advanced the cursor; a cluster cell emits its whole grapheme;
          # a wide cell claims its continuation cell, which the next iteration
          # skips (keeping cell index == terminal column).
          if fu
            # The cell's base codepoint. NOT `desired_char`, which may have been
            # ACS-reduced above.
            base_char = l_chars.unsafe_fetch(x)
            if base_char == Cell::CONTINUATION
              # Orphan continuation cell reached WITHOUT `skip_next` (its lead was
              # unchanged and skipped, or clipped off the left edge). Nothing is
              # printed for it, so the terminal cursor did NOT advance: force the
              # next changed cell to reposition absolutely, or it prints one column
              # too far left and persists the error into `@flushed_lines`.
              lx = x
              ly = -1
            else
              # A replacing artificial cursor (`acur_glyph`) suppresses the overlay
              # so its own glyph is emitted instead of the underlying cluster.
              g = (l_has_g && !acur_glyph) ? line.grapheme_at?(x) : nil
              # Equivalent to `current.width` here: the continuation case is
              # excluded above, so width comes from the overlay cluster if present,
              # the cursor glyph when it replaced the cell, else the codepoint.
              w = g ? ::Crysterm::Unicode.width(g) : ::Crysterm::Unicode.width(acur_glyph ? desired_char : base_char)
              if g
                if ascii_reduce
                  # Non-UTF8 terminal: never emit the raw multibyte cluster (several
                  # bytes for one cell). Reduce to the base codepoint's ASCII
                  # fallback, mirroring the lone-codepoint reduction above.
                  @outbuf.print(base_char > '~' ? ascii_fallback(base_char) : base_char)
                else
                  @outbuf.print g
                end
              else
                @outbuf.print desired_char
              end
              # A width-2 cell is never placed at the last column — any lead cell
              # lacking an in-region continuation is blanked at render time — so
              # this claim never over-runs the buffer and the nil-guard is
              # defensive only.
              if w == 2 && (oc = o[x + 1]?)
                oc.attr = desired_attr
                oc.continuation!
                skip_next = true
                # An ASCII-reduced 2-column glyph printed only ONE column, but
                # `skip_next` advances the cell index by two. Pad so the terminal
                # cursor advances two columns and stays in step.
                @outbuf.print ' ' if ascii_reduce
              end
            end
          else
            @outbuf.print desired_char
          end

          attr = desired_attr
        end

        # Reproduce the cursor-run state a full scan would leave: it would walk the
        # trailing unchanged cells and record the start of that run, so the *next*
        # row's reposition math matches the full scan exactly.
        if scan_hi < line_size - 1 && lx == -1
          lx = scan_hi + 1
          ly = y
        end

        if attr != @default_attr
          @outbuf.print "\e[m"
        end

        unless @outbuf.empty?
          emit_cursor_position(@main, ansi_cursor, y, 0)
          @main.write @outbuf.to_slice
        end
      end

      # Close any hyperlink left open by the last emitted run, so link state
      # never leaks past a frame (and `cur_link = 0` at the top holds).
      if cur_link != 0_u16
        emit_link(@main, 0_u16)
        cur_link = 0_u16
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
        # it doesn't streak across the screen as the cell runs are emitted, then
        # restore it. This MUST go straight to `tput`, not `Window#hide_cursor`/
        # `#show_cursor`: those dispatch on the *active* cursor and, when it is
        # artificial, write no escape (leaving the hardware cursor streaking) and
        # schedule a redundant render from *inside* `draw`.
        #
        # On the `ansi_cursor` fast path the bracket sequences are the constants
        # cached in `DrawCaps`, written straight into the buffers rather than via
        # `tput.save_cursor`/… (whose per-call `.dup` cost ~48-80 B on every
        # output-producing frame). Safe because draw's own cursor moves are raw
        # inline ANSI that never touch tput's software cursor tracker, so only the
        # physical bytes matter. A non-conforming terminal keeps the tput path,
        # which also maintains that software cursor state.
        if ansi_cursor
          @pre.write caps.save_cursor
          @pre.write caps.hide_cursor unless hidden
          @post.write caps.restore_cursor
          @post.write caps.show_cursor unless hidden
        else
          divert(@tmpbuf, @pre) do
            tput.save_cursor
            tput.hide_cursor unless hidden
          end

          divert(@tmpbuf, @post) do
            tput.restore_cursor
            tput.show_cursor unless hidden
          end
        end

        # Account for the bytes to be emitted. `@_buf`'s buffered
        # insert/delete-line output was folded into `@main` above, so the three
        # buffers cover everything `draw` sends this frame.
        @last_draw_bytes = @pre.size + @main.size + @post.size
        @bytes_written += @last_draw_bytes
        @_frame_pending = true
      end

      flush_frame if flush
    end

    # Writes the frame `#draw` built (`@pre`+`@main`+`@post`) to the terminal.
    #
    # Split out of `#draw` so the terminal write can be timed on its own. On an
    # unbuffered tty (`Superconf.tput_use_buffer` off — the default) this is a
    # blocking `write()`; once the per-frame payload exceeds the pty buffer it
    # stalls at the terminal's refresh cadence, so this — not the diff/encode in
    # `#draw` — is where terminal backpressure shows up. A no-op when `draw`
    # produced no output this frame.
    def flush_frame : Nil
      return unless @_frame_pending
      @_frame_pending = false

      # Bracket the frame in a DEC 2026 synchronized update (when enabled) so the
      # terminal presents it atomically. Inlined into one `_print` so the markers
      # and the frame land in a single write, and none are emitted on empty frames.
      tput._print do |io|
        io << "\e[?2026h" if synchronized_output?
        io.write @pre.to_slice
        io.write @main.to_slice
        io.write @post.to_slice
        io << "\e[?2026l" if synchronized_output?
      end
    end

    # Shifts the cell buffer (`@lines`/`@flushed_lines`) *down* by `n` rows: a blank line
    # appears at `y` and the line that was at `bottom` falls off — the buffer-side
    # counterpart of the terminal `il`/scroll-down.
    private def shift_lines_down(n, y, bottom)
      shift_lines n, insert_at: y, delete_at: bottom + 1
    end

    # Shifts the cell buffer (`@lines`/`@flushed_lines`) *up* by `n` rows: the line at `y`
    # is removed and a blank line appears at `bottom` — the buffer-side counterpart
    # of the terminal `dl`/scroll-up.
    private def shift_lines_up(n, y, bottom)
      shift_lines n, insert_at: bottom + 1, delete_at: y
    end

    # Shifts both cell buffers `n` times so a blank line appears at `insert_at` and
    # the line at `delete_at` falls off. The evicted row is recycled (deleted,
    # blanked in place, re-inserted) rather than allocating a fresh blank row
    # per shift; each buffer only ever recycles its own row, so the two stay
    # independent.
    #
    # Deleting first shifts the indices: `insert(I); delete(D)` removes the
    # *pre-insert* element at `D` (if `D < I`) or `D - 1` (if `D > I`), and lands
    # the blank at `I` (if the removal was above `I`) or `I - 1` (if below). Each
    # iteration is size-neutral, so the indices are constant across all `n`.
    private def shift_lines(n, insert_at, delete_at)
      removed = delete_at < insert_at ? delete_at : delete_at - 1
      final_insert = removed < insert_at ? insert_at - 1 : insert_at
      n.times do
        recycle_shifted_row @lines, removed, final_insert
        recycle_shifted_row @flushed_lines, removed, final_insert
      end
    end

    # Evicts the row at `removed_at` from `buf`, blanks it to the current screen
    # width (rebuilding cell count if the screen resized since the row was built),
    # and re-inserts it at `insert_at`.
    private def recycle_shifted_row(buf : Array(Row), removed_at : Int32, insert_at : Int32) : Nil
      row = buf.delete_at removed_at
      aw = awidth
      # Match the current width if the screen resized since this row was built.
      while row.size > aw
        row.pop
      end
      # Blank the existing cells (also drops any grapheme overlay).
      row.clear_to @default_attr, ' '
      while row.size < aw
        row.push @default_attr, ' '
      end
      # A blank shifted line is not dirty — the terminal's own il/dl scrolled it.
      row.dirty = false
      buf.insert insert_at, row
    end

    # Verifies the terminfo capabilities the `insert_line`/`delete_line` family
    # needs (always change-scroll-region + delete-line; plus insert-line when
    # *need_insert_line*), then runs *block* with output diverted to `@_buf` and
    # the scroll region temporarily set to `top..bottom`, restoring the full screen
    # afterwards. Returns `false` when a missing capability made it a no-op, in
    # which case the caller must not shift its buffer either.
    private def with_scroll_region(top, bottom, need_insert_line = false, & : IO::Memory ->) : Bool
      if !tput.has?(&.change_scroll_region?) ||
         !tput.has?(&.delete_line?) ||
         (need_insert_line && !tput.has?(&.insert_line?))
        STDERR.puts "Missing needed terminfo capabilities"
        return false
      end

      off = render_row_offset
      divert(@tmpbuf, @_buf) do |buf|
        tput.set_scroll_region(top + off, bottom + off)
        yield buf
        # Restore the full screen; in alt mode (`off == 0`) that IS the surface's
        # own bounds. An inline surface must NOT leave DECSTBM pinned to its band:
        # auto-grow emits newlines at the terminal's last row, below the band's
        # bottom, so a pinned region makes the next autogrow scroll a no-op (or
        # scroll only the band), desyncing `render_row_offset` and painting over
        # shell history.
        tput.set_scroll_region(0, (@alternate ? aheight : tput.screen.height) - 1)
      end
      true
    end

    # Inserts lines into the screen. (If CSR is used, it bypasses the output buffer.)
    def insert_line(n, y, top, bottom)
      return unless with_scroll_region(top, bottom, need_insert_line: true) do
                      tput.cup(y + render_row_offset, 0)
                      tput.il(n)
                    end

      shift_lines_down n, y, bottom
    end

    # Inserts lines into the screen using ncurses-compatible method. (If CSR is used, it bypasses the output buffer.)
    #
    # This is how ncurses does it.
    # Scroll down (up cursor-wise).
    # This will only work for top line deletion as opposed to arbitrary lines.
    protected def insert_line_nc(n, y, top, bottom)
      return unless with_scroll_region(top, bottom) do
                      tput.cup(top + render_row_offset, 0)
                      tput.dl(n)
                    end

      shift_lines_down n, y, bottom
    end

    # Deletes lines from the screen. (If CSR is used, it bypasses the output buffer.)
    def delete_line(n, y, top, bottom)
      # Only emits `dl`, so it must not require `il`: on a terminal advertising CSR
      # + delete_line but not insert_line that would make this a silent no-op,
      # dropping the buffer-side `shift_lines_up` too.
      return unless with_scroll_region(top, bottom) do
                      tput.cup(y + render_row_offset, 0)
                      tput.dl(n)
                    end

      shift_lines_up n, y, bottom
    end

    # Deletes lines from the screen using ncurses-compatible method. (If CSR is used, it bypasses the output buffer.)
    #
    # This is how ncurses does it.
    # Scroll down (up cursor-wise).
    # This will only work for top line deletion as opposed to arbitrary lines.
    protected def delete_line_nc(n, y, top, bottom)
      return unless with_scroll_region(top, bottom) do |ret|
                      tput.cup(bottom + render_row_offset, 0)
                      # Emit `n` newlines without materializing a `"\n" * n` String.
                      n.times { ret << '\n' }
                    end

      shift_lines_up n, y, bottom
    end

    # Deletes line at bottom of screen.
    def delete_bottom(top, bottom)
      # `clear_region` is half-open in `y`, so the far edge must be ONE PAST the
      # row to clear; `bottom, bottom` would iterate zero rows.
      clear_region(0, awidth, bottom, bottom + 1)
    end

    # Checks whether an element has uniform cells on both sides; if so, CSR can be
    # used to optimize scrolling on a scrollable element. Not exactly sure how
    # worthwhile this is — it costs CPU, but maybe less than slow-rendering
    # scrollable boxes with clean sides would.
    protected def sides_uniform?(el)
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

      yi = pos.yi + el.itop
      yl = pos.yl - el.ibottom

      return pos._clean_sides = false if pos.yi < 0 || pos.yl > aheight
      return pos._clean_sides = true if (pos.xi - 1) < 0 || pos.xl > awidth

      # Both the band of columns left of the element and the band to its right must
      # be uniform top-to-bottom for the sides to count as clean.
      (pos.xi - 1).downto(0) do |x|
        return pos._clean_sides = false unless column_uniform? x, yi, yl
      end

      (pos.xl...awidth).each do |x|
        return pos._clean_sides = false unless column_uniform? x, yi, yl
      end

      pos._clean_sides = true
    end

    # Whether column *x* of `@flushed_lines` holds the same cell on every row of
    # `yi...yl`, comparing against the top row's cell. A row missing the column
    # stops the scan early; a missing top row leaves the reference nil, so the scan
    # breaks before any comparison.
    private def column_uniform?(x, yi, yl) : Bool
      first = @flushed_lines[yi]?.try &.[x]?
      yi.upto(yl - 1) do |y|
        row = @flushed_lines[y]?
        break unless row && (ch = row[x]?)
        return false if ch != first
      end
      true
    end

    # Clears any chosen region on the screen.
    #
    # The region is half-open: `[xi, xl) × [yi, yl)` — `xl`/`yl` are one PAST
    # the last column/row cleared.
    def clear_region(xi, xl, yi, yl, *, force : Bool = false)
      fill_region @default_attr, ' ', xi, xl, yi, yl, force: force
    end

    # Forces the cells in the given region to be re-emitted to the terminal on the
    # next `#draw`, even if their content is unchanged from the previous frame.
    #
    # `#draw` skips cells that match `@flushed_lines` (what's on the terminal), but a
    # widget drawing *outside* the cell model — a w3m image painted on top of the
    # terminal — needs the cells underneath a stale overlay physically re-emitted
    # so text redraws over it. Poisoning `@flushed_lines` makes the diff treat those cells
    # as changed.
    def invalidate_region(xi, xl, yi, yl)
      # The selective damage path can't reason about writes outside the cell model.
      note_effect

      xi = 0 if xi < 0
      yi = 0 if yi < 0

      yi.upto(yl - 1) do |y|
        oline = @flushed_lines[y]?
        break unless oline

        line = @lines[y]?

        # The poison sentinel '\0' equals `Cell::CONTINUATION`: when the rect's
        # LEFT edge lands on the trailing half of a wide grapheme, the desired cell
        # is *also* '\0' with the same attr and compares unchanged, so the glyph
        # straddling the edge would never repaint. Widen the poison one column left
        # so the LEAD cell is re-emitted and re-claims its continuation.
        x0 = xi
        if x0 > 0 && line && (c = line[x0]?) && c.continuation?
          x0 -= 1
        end

        x0.upto(xl - 1) do |x|
          ocell = oline[x]?
          break unless ocell
          # A sentinel the real cell content can never equal, so `draw` re-emits.
          ocell.char = '\u{0}'
        end

        line.try(&.dirty=(true))
      end
    end

    # Walks every existing cell of the rectangular region `[xi, xl) × [yi, yl)` in
    # `@lines`, yielding each cell together with its line. A row's scan stops at
    # the first missing cell and the whole walk stops at the first missing row.
    # With `clamp` (the default) a negative `xi`/`yi` origin is pulled back to 0.
    #
    # A negative index is treated as off the top/left of the grid and SKIPPED. This
    # must be explicit: Crystal's `Indexable#[]?` counts a negative index *from the
    # end* (`@lines[-1]?` is the last row, not `nil`), so a `clamp: false` caller
    # passing a negative origin would otherwise wrap around and paint onto the
    # OPPOSITE edge. Off the bottom/right (index >= size) correctly yields `nil`.
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
    # This is the per-frame full-screen clear path, so unlike `each_region_cell` it
    # hoists each row's backing arrays and width and indexes with
    # `unsafe_fetch`/`unsafe_put`. `xi`/`yi` are clamped to >= 0 and cells are
    # contiguous, so a cell is "missing" only past the row end (`xend`) — every
    # `unsafe_*` is provably in range.
    #
    # For a *scattered* single cell (a dial pointer, a spaced slider tick) with no
    # contiguous run to batch, pass a 1x1 region
    # (`fill_region attr, ch, x, x + 1, y, y + 1`): it change-guards the write and
    # narrows the dirty range to that one column.
    #
    # The region is half-open: `[xi, xl) × [yi, yl)` — `xl`/`yl` are one PAST
    # the last column/row filled.
    def fill_region(attr, ch, xi, xl, yi, yl, *, force : Bool = false)
      xi = 0 if xi < 0
      yi = 0 if yi < 0

      yi.upto(yl - 1) do |y|
        line = @lines[y]?
        break unless line

        attrs = line.attrs
        chars = line.chars
        n = attrs.size
        xend = xl < n ? xl : n
        # Whether this row carries ANY grapheme overlay, hoisted once: most rows in
        # this per-frame clear path have none, and the per-cell overlay calls
        # otherwise dominate the render profile.
        has_g = line.has_graphemes?
        # Same hoist for the hyperlink overlay. This raw-array writer must uphold
        # `Cell#char=`'s invariant that every content write clears the cell's link,
        # or blanked cells keep stale link ids and are re-emitted wrapped in OSC 8
        # as invisible clickable regions, with the row permanently `has_links?`.
        has_l = line.has_links?

        x = xi
        while x < xend
          # Equivalent to `cell != {attr, ch}`: a cell carrying a grapheme overlay
          # is never equal to a single-char tuple, so it must be rewritten, and so
          # must a linked cell — an already-blank one would otherwise be skipped
          # with its link intact.
          if force || attrs.unsafe_fetch(x) != attr || chars.unsafe_fetch(x) != ch ||
             (has_g && !line.grapheme_at?(x).nil?) || (has_l && line.link_at(x) != 0_u16)
            attrs.unsafe_put(x, attr)
            chars.unsafe_put(x, ch)
            # Mirror `Cell#char=`'s side effects: drop the cluster and link overlays.
            line.delete_grapheme(x) if has_g
            line.delete_link(x) if has_l
            # Narrow the dirty range to this column so `draw` can bound its scan.
            line.mark_dirty x
          end
          x += 1
        end
      end
    end

    # Writes one wide (2-column) glyph directly into window cells: a lead cell
    # at `(x, y)` plus a claimed continuation cell at `(x + 1, y)`, both
    # carrying *attr*. Upholds the same "a width-2 cell is always followed by
    # an in-region continuation" invariant the content draw path maintains
    # (see the claim/blank pair around line 566 and 606 above), for
    # direct-paint widgets (`Marquee`, `Effect::SineScroller`) that bypass the
    # content pipeline and write cells straight via `#fill_region`.
    #
    # The caller is responsible for confirming `x + 1` is still within the
    # widget's own content region before calling — a lead with no in-region
    # continuation must be left blank instead (half a wide glyph can't
    # render), mirroring `widget_rendering.cr`'s edge-blanking. Built on top
    # of `#fill_region` so it gets the same change-guarding, dirty-marking,
    # and grapheme/link overlay cleanup for free.
    def put_wide(attr : Int64, ch : Char, x : Int32, y : Int32) : Nil
      fill_region(attr, ch, x, x + 1, y, y + 1)
      fill_region(attr, Cell::CONTINUATION, x + 1, x + 2, y, y + 1)
    end

    # Alpha-blends every cell in a region toward black (shadow compositing).
    # Unlike `fill_region` this does NOT clamp `xi`/`yi` to 0: shadow callers pass
    # intentionally unclamped bounds and rely on the lookups skipping whatever
    # falls off the grid.
    #
    # With *glyph* set (a half-block such as `▀`/`▄`/`▌`/`▐`), the band is painted
    # with that character instead of darkening the whole cell, so only part of the
    # cell reads as shadow — a thin shadow that escapes the terminal's ~2:1 cell
    # aspect ratio.
    #
    # The shadow tone is carried by the cell's *background*, not the glyph's
    # foreground: a background is a solid fill that reaches the cell edges, whereas
    # a foreground half-block can leave a hairline gap in some fonts. The glyph's
    # foreground instead paints the untouched backdrop over the complementary half.
    # So pick the glyph whose *solid* half faces AWAY from the widget: `▄` shadows
    # the top half (bottom-edge shadow), `▀` the bottom, `▐` the left half
    # (right-edge shadow), `▌` the right.
    def blend_region(alpha, xi, xl, yi, yl, glyph : Char? = nil)
      each_region_cell(xi, xl, yi, yl, clamp: false) do |cell, _line|
        if glyph
          base = cell.attr
          shadowed = Colors.blend(base, alpha: alpha)
          # bg = darkened backdrop (the solid shadow half), fg = untouched backdrop
          # (the glyph half). Flags cleared so the glyph isn't bold/underlined/etc.
          cell.set_if_changed Attr.pack(0_i64, Attr.bg(base), Attr.bg(shadowed)), glyph
        else
          cell.attr = Colors.blend(cell.attr, alpha: alpha)
          cell.mark_dirty
        end
      end
    end

    # Tints every cell in the region toward `color` by `alpha` (`0` = unchanged,
    # `1` = fully `color`) — the color overlay behind `style.tint`. Like
    # `#blend_region` but toward an arbitrary color instead of black.
    def tint_region(alpha, color, xi, xl, yi, yl)
      each_region_cell(xi, xl, yi, yl) do |cell, _line|
        cell.attr = Colors.tint(cell.attr, color, alpha)
        cell.mark_dirty
      end
    end
  end
end
