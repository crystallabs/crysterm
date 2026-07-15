module Crysterm
  class Window
    # Drawing (displaying rendered state on screen).
    #
    # "Rendering" fills an (Y,X) array of cells in memory with the desired
    # attributes and character (a framebuffer). "Drawing" diffs current vs.
    # desired screen state and emits the text + escape sequences needed to
    # match the terminal to it in as few sequences as possible.

    # Any prefix we want the final buffer to have
    @_buf = IO::Memory.new

    # Final buffer of data to print to screen: content + escape sequences.
    @main : IO::Memory = IO::Memory.new 10_240 * 10

    # Temporary buffer for content and escape sequences for each individual row.
    @outbuf : IO::Memory = IO::Memory.new 10_240

    # Even more temporary buffer, for parts of a row and the short escape bursts
    # of line insert/delete ops. Cleared by `divert` before use, so it's shared
    # across these non-overlapping uses instead of allocating throwaways.
    @tmpbuf : IO::Memory = IO::Memory.new 64

    # From rendering:
    # @lines - Grid of desired cell contents in memory, the "framebuffer"

    protected property render_index_cursor = -1

    # Position where an artificial cursor was painted on the previous `draw`, or
    # `-1` when none. When the cursor moves rows (or stops), the vacated cell
    # must be repaired — see the repair note in `#draw`.
    @_acur_x = -1
    @_acur_y = -1

    @pre = IO::Memory.new 1024
    @post = IO::Memory.new 1024

    # Set by `#draw` when it produced output (`@pre`+`@main`+`@post`) that has
    # not yet been written to the terminal; consumed (and cleared) by
    # `#flush_frame`. Lets the caller time the diff/encode (`draw`) and the
    # blocking terminal write (`flush_frame`) separately — see `#_render`.
    @_frame_pending = false

    # Terminal control values used by the per-frame `#draw`, derived from the
    # connected terminal (terminfo + features) and constant for the screen's
    # lifetime — computed **once** here rather than per frame/cell. Static
    # parameter-free sequences (`smacs`/`rmacs`/`el`) are captured (`dup`'d off
    # terminfo's memory) for writing straight into the frame buffer. Parameterized
    # hot-path sequences (`cup`/`cuf`/SGR) are emitted as direct ANSI at their call
    # sites (terminfo `run` allocates a `Bytes` per call), gated on `ansi_cursor`
    # so a non-conforming terminal falls back to the tput path. `DrawCaps` and
    # `#compute_draw_caps` live on the device `Window`; read here via `#draw_caps`.

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
      # Clear so the buffer can be reused across calls.
      buf.clear
      tput.ret = buf
      begin
        yield buf
        dest.write buf.to_slice
      ensure
        tput.ret = nil
      end
    end

    # Reduces a non-ASCII glyph to its ASCII fallback (index 2 of the ACSC
    # table entry), or `'?'` when the glyph has no ACS mapping. Shared by the
    # lone-codepoint and grapheme-cluster reduction paths below.
    private def ascii_fallback(ch : Char) : Char
      Tput::ACSC::Data[ch]?.try(&.[2]) || '?'
    end

    # Emits a cursor move to (`y`, `x`) (0-based) into `dest`: direct ANSI
    # (`\e[<row>;<col>H`, 1-based) when `ansi_cursor`, else the terminfo path
    # via `#divert`. Shared by the per-run reposition and line-start moves below.
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
    # eliminating flicker/tearing on a multi-write redraw. Markers are emitted
    # only on frames that produce output, in the same write. Harmless on
    # unsupporting terminals (ignored, auto-release after a timeout). Default
    # from `Config.render_synchronized_output` (on).
    property? synchronized_output : Bool = Config.render_synchronized_output

    # Whether cells carrying a hyperlink id draw with OSC 8 hyperlink escapes
    # (`\e]8;;URI\e\\` … `\e]8;;\e\\`), making anchors clickable/hoverable on
    # supporting terminals. Unknown OSC sequences are ignored by terminals, so
    # this is safe to leave on. Default from `Config.render_hyperlinks`. When
    # off, `#link_id` registers nothing, so no cell ever carries a link.
    property? hyperlinks : Bool = Config.render_hyperlinks

    # OSC 8 hyperlink registry: cells store a compact `UInt16` id (see
    # `Cell#link=`); the URIs live here, deduplicated. Id `0` is "no link".
    @link_urls = [] of String
    @link_ids = {} of String => UInt16

    # Registers *url* and returns its cell link id — the value to assign to
    # `Cell#link=` for every cell the link covers. Returns `0` (no link) for
    # an empty URL, when `#hyperlinks?` is off, or if the registry is
    # (improbably) full; URLs are sanitized of control characters and
    # length-capped, since they travel inside an escape sequence.
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
      return nil if id == 0
      @link_urls[id - 1]?
    end

    # Emits the OSC 8 sequence switching the terminal's "current hyperlink"
    # to *id*'s URI (`0` = close): printed cells from here on carry the link.
    # The sequences come from tput (`begin_hyperlink`/`end_hyperlink`),
    # captured into *dest* via `#divert` like the other tput-routed draw
    # output. Cheap enough off the per-cell fast path — it runs only when a
    # printed cell's link differs from the one in effect.
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
    # Diffs `@lines` against `@olines` and encodes the needed escapes into the
    # frame buffers (`@pre`/`@main`/`@post`), then — unless *flush* is false —
    # writes them to the terminal via `#flush_frame`. `#_render` passes
    # `flush: false` so it can time the diff/encode and the (blocking) terminal
    # write separately; direct callers (specs, external code) get the full
    # build-and-write in one call.
    def draw(start = 0, stop = @lines.size - 1, flush = true)
      # D O:
      # emit Event::PreDraw

      @main.clear
      # No output produced yet this frame; updated below if a payload is written.
      @last_draw_bytes = 0
      # @outbuf.clear # Done below, for every line (`y`)
      lx = -1
      ly = -1
      acs = false
      # OSC 8 hyperlink currently in effect on the terminal (0 = none). Cells
      # print under it; emission switches it when a printed cell's link id
      # differs, and the frame closes it before finishing, so every frame
      # starts link-free.
      cur_link = 0_u16

      # Terminal-constant capabilities (`@draw_caps`, via `#compute_draw_caps`),
      # bound to locals here. Only `bce_opt`, `fu` and `ncolors` can change at
      # runtime, so they stay per-frame.
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
      # `@default_attr` is constant for the whole draw() call, so the bg/deco
      # fields the BCE look-ahead gate compares against are hoisted here
      # instead of being re-extracted from `@default_attr` per candidate space
      # cell.
      default_bg = Attr.bg(@default_attr)
      default_deco = Attr.flags(@default_attr) & (Attr::REVERSE | Attr::UNDERLINE | Attr::STRIKE)
      fu = full_unicode?
      # Output color depth used to reduce SGR colors. NOT taken from the frozen
      # `caps.ncolors` (computed once at `compute_draw_caps`): `#colors` resolves
      # the `colors.depth` config/env override fresh, so a depth changed at
      # runtime (e.g. toggling truecolor) actually reaches the wire. Computed
      # once per frame, not per cell.
      ncolors = colors
      # When full_unicode is on but the terminal declares neither unicode nor U8,
      # non-ASCII glyphs are reduced to a 1-column ASCII fallback (see the emit
      # path). A wide (2-column) cell whose glyph is reduced must still pad its
      # output so the terminal cursor advances two columns, matching the claimed
      # continuation cell. Constant for the frame.
      ascii_reduce = !term_unicode && (u8 != 1)
      # Whether the per-row scan may be bounded to the dirty-column range.
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
      # Constant for the whole draw, so hoisted out of the per-row/per-cell hot path.
      c_artificial = c.artificial?
      cursor_x = tput.cursor.x
      # The tracker holds the PHYSICAL row — every positioning path adds
      # `render_row_offset` before `cup` (`move_terminal_caret`, `enter_inline`,
      # marker checks) — while this method compares against surface rows
      # (`@lines` indices), so translate back. A no-op in full-screen mode
      # (offset 0); may go negative when the cursor sits above an inline
      # region, which correctly fails the `>= start` guard below.
      cursor_y = tput.cursor.y - render_row_offset

      # Repair the cell a previously-painted artificial cursor left behind.
      # `draw` only scans dirty rows or the cursor's row, so when the cursor
      # moves to another row (or stops), the old row is otherwise untouched and
      # the cursor glyph in `@olines` would never be diffed away — a ghost cursor.
      # Mark the vacated cell dirty so the diff re-emits the real content. A
      # same-row move is covered by the full scan that row gets.
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

        # Skip if no change in line. Checked BEFORE the row hoists below (line
        # size, backing arrays, grapheme/link overlay probes): this depends
        # only on line.dirty/c_artificial/y/cursor_y, so on any skipped row
        # none of that hoisting work is needed at all.
        if !line.dirty && !(c_artificial && (y == cursor_y))
          next
        end

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
        # once: when neither does (the common case), the per-cell `grapheme_at?`
        # probes all compare nil==nil and are skipped wholesale. `false` when
        # full_unicode is off, collapsing the guards to a constant.
        l_has_g = fu && line.has_graphemes?
        o_has_g = fu && o.has_graphemes?
        any_g = l_has_g || o_has_g

        # Same hoist for the hyperlink overlays: link-free rows (the common
        # case) skip every per-cell link probe.
        l_has_l = line.has_links?
        o_has_l = o.has_links?
        any_l = l_has_l || o_has_l

        # ::Log.trace { line } if line.any? &.char.!=(' ')

        # Bound the per-cell scan to the columns that actually changed
        # (`[scan_lo, scan_hi]`), read before the dirty flag is cleared below.
        # Only on the common fast path — BCE, full_unicode, or an artificial
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
        # reads).
        acur_col = (draw_acur && y == cursor_y) ? cursor_x : -1

        # When the scan starts past column 0, seed the skipped-run cursor as the
        # full scan's leading run over [0, scan_lo) would: set `lx = 0, ly = y`
        # only if `lx` was -1 at row start; a leftover non-(-1) `lx` is preserved
        # (so the first changed cell repositions with an absolute `cup`, matching
        # the full scan). The row is prefixed with a cup to column 0 below.
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

          # Render the artificial cursor. `acur_col` already encodes the whole
          # `c_artificial && !c._hidden && c._state != 0 && y == cursor_y`
          # condition per row (or -1), so this is one compare per cell.
          #
          # `acur_glyph` records whether the cursor *replaced* this cell's glyph
          # with its own: the line and custom (`none`) shapes return a char (a
          # bar `│` / the custom `fill_char`), while block/underline return nil
          # and keep the cell's own char, changing only the attribute. A
          # replacing cursor's single-codepoint glyph must win over any
          # grapheme-cluster overlay the cell carries — otherwise the `fu` emit
          # path below re-reads the overlay and the cursor glyph is never shown.
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
          # The flag-parity gate must cover every attribute that visibly
          # decorates a printed *space*: `el` fills with the background only,
          # so a run of UNDERLINE/STRIKE (not just REVERSE) blanks would come
          # out undecorated — and, `@olines` being mirrored as-drawn, stay
          # missing forever.
          if bce_opt && (desired_char == ' ') && (x > bce_skip_until) &&
             (has_bce || (Attr.bg(desired_attr) == default_bg)) &&
             ((Attr.flags(desired_attr) & (Attr::REVERSE | Attr::UNDERLINE | Attr::STRIKE)) == default_deco)
            clr = true
            neq = false # line changed content vs. previous render
            breaker = line_size

            (x...line_size).each do |xx|
              lc_attr = l_attrs.unsafe_fetch(xx)
              lc_char = l_chars.unsafe_fetch(xx)

              # `line[xx] != {desired_attr, ' '}`: is this a clearable space? Read
              # from the hoisted arrays; under full_unicode a cell holding a
              # multi-codepoint cluster is never a bare space even if its base
              # codepoint is one, so the overlay must be nil.
              clearable = lc_attr == desired_attr && lc_char == ' '
              # The artificial-cursor cell is never clearable (see `acur_col`): its
              # reverse/glyph attribute lives only in the per-cell loop's
              # `desired_attr`, not in the buffer this look-ahead reads, so clearing
              # over it with `el` would drop the cursor for the frame.
              clearable = false if xx == acur_col
              # Only probe the overlay when this row actually has one; with none,
              # `grapheme_at?` is nil and `clearable &&= true` is a no-op.
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
              # With no overlay on either side both probes are nil, so the
              # comparison is nil != nil (false) — skip it.
              changed ||= line.grapheme_at?(xx) != o.grapheme_at?(xx) if any_g
              changed ||= line.link_at(xx) != o.link_at(xx) if any_l
              neq = true if changed
            end

            # If the tail wasn't clearable, the offending cell at `breaker` stays
            # in range for every column in (x, breaker), and the run (x, breaker)
            # shares `desired_attr`, so those scans would reach the same verdict —
            # skip them. `breaker` itself may begin a new run (different attr), so
            # it is left scannable.
            bce_skip_until = breaker - 1 unless clr

            # This block clears a line if it's not clear but needs to be.
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
                # Reset first when the terminal currently has any non-default
                # attribute active. `code2attr_to` writes the target attr from a
                # *blank* SGR state and emits NOTHING for the default attr (see
                # Screen.code2attr_to), so without this reset a transition to the
                # default attr would leave the previous cell's color/flags active:
                # the `el` below would erase the rest of the line with that stale
                # background (BCE), and the leftover SGR would bleed into cells/rows
                # drawn afterward. Mirrors the per-cell path's `\e[m`-then-set
                # sequence below.
                @outbuf.print "\e[m" if attr != @default_attr
                attr = desired_attr
                # Allocation-free SGR emission straight into the line buffer;
                # `code2attr` would allocate a fresh String for every cleared
                # line, every frame (see Screen.code2attr_to).
                Screen.code2attr_to(@outbuf, attr, ncolors)
              end

              # Clear to end of line at (x, y): a cursor move (see the reposition
              # note below) followed by the hoisted static `el`.
              emit_cursor_position(@outbuf, ansi_cursor, y, x)
              @outbuf.write el

              # Mirror the cleared run into `@olines` through the hoisted
              # backing arrays — `o[xx].attr=`/`.char=` built two bounds-checked
              # `Cell` handles per cell. Overlay cleanup (the `char=` side
              # effect) is needed only when the old row carries any overlay;
              # writes never install one at ≥ x mid-row, so the row-start
              # `o_has_g` still decides.
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
          # the terminal (`@olines`). An unchanged cell is skipped entirely;
          # `lx`/`ly` remember the start of the skipped run so the next changed
          # cell repositions over it with a single cursor move (cuf or cup)
          # instead of redrawing it.
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
            # overlay, so the compare is just `attr == && char ==`, skipping the
            # `@graphemes` lookup on this hot path.
            #
            # Under `full_unicode` a cell's value also includes its grapheme
            # cluster, so the new cell's overlay is compared against the old one
            # (`ox == line[x]` semantics) — `desired_char` is only the cluster's
            # BASE codepoint, so without this a cell going from 'e' to a combining
            # 'e'+◌́ (same base, same attr) would be wrongly skipped and the mark
            # never emitted; conversely an unchanged cluster cell would be
            # needlessly re-emitted every frame. `grapheme_at?` is the same lookup
            # `Cell#grapheme_overlay` does, without constructing a `Cell`.
            #
            # `legacy_cell_eq` still forces a miss for A/B benchmarking.
            # `unchanged` is declared here (not inside the macro `if`) so it stays
            # visible below.
            unchanged = false
            {% unless flag?(:legacy_cell_eq) %}
              unchanged = o_attrs.unsafe_fetch(x) == desired_attr && o_chars.unsafe_fetch(x) == desired_char
              # Skip the overlay compare when neither row has one (nil == nil is
              # true, leaving `unchanged` as-is).
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
              # direct ANSI straight into the buffer rather than via terminfo:
              # these carry (x,y)/distance parameters and fire per run-break every
              # frame, so terminfo `run` would allocate a fresh `Bytes` each call.
              # `cuf` (`\e[<n>C`) and `cup` (`\e[<row>;<col>H`, 1-based) are
              # universal on every terminal Crysterm targets (it already assumes
              # ANSI SGR), so the hardcoded forms match terminfo's output. Writing
              # an `Int` to the IO emits its digits with no `String` allocation.
              if ansi_cursor && parm_right_cursor && y == ly
                @outbuf << "\e[" << (x - lx) << 'C'
              else
                # Non-conforming terminal: route through tput (captured into the
                # frame buffer via `divert`). Always an absolute move, since this
                # path can't assume `cuf` either.
                emit_cursor_position(@outbuf, ansi_cursor, y, x)
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
            # `line.grapheme_at?(x)` is `line[x].grapheme_overlay` without the
            # bounds-checked `Cell` handle; rows with no overlay skip the probe
            # entirely via `l_has_g`.
            if fu && l_has_g && !acur_glyph && (g = line.grapheme_at?(x))
              ox.grapheme = g
            else
              ox.char = desired_char
            end
            # Mirror the link too. The content writes above just cleared the
            # old side's link, so only a present link needs storing.
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

              # Emit the SGR flags/colors via the shared helper (also used by
              # `Screen.code2attr_to`). If anything was written it ends in a ';',
              # backed over and replaced with the terminating 'm'. Always emit
              # "\e[" + "m" here (a bare reset "\e[m" when nothing was written)
              # because reaching this branch means `desired_attr != @default_attr`,
              # unlike `code2attr_to`'s "emit nothing for the default attr" contract.
              if Screen.sgr_params_to(@outbuf, desired_attr, ncolors)
                @outbuf.seek -1, IO::Seek::Current
              end

              @outbuf.print 'm'
              # ::Log.trace { @outbuf.inspect }
            end
          end

          # Switch the terminal's "current hyperlink" (OSC 8) when this
          # printed cell's link id differs from the one in effect. Link-free
          # rows with no link open skip this in one compare.
          if l_has_l || cur_link != 0_u16
            lid = l_has_l ? line.link_at(x) : 0_u16
            if lid != cur_link
              emit_link(@outbuf, lid)
              cur_link = lid
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

          # Attempt to use ACS for supported characters. Not ideal, but it's how
          # ncurses works: many terminals support both ACS and UTF8 but don't
          # declare U8, so ACS ends up used (slower than utf8); terminals
          # supporting neither get unicode chars replaced with ascii fallbacks.
          # Maybe remove the !tput.unicode check, but this matches ncurses.
          #
          # This IF/ELSE block may print a prefix to @outbuf, but 'ch' is always
          # written after it regardless — keep that in mind if changing the logic.
          # `acscr` is keyed only by non-ASCII glyphs in the `!broken_acs` case
          # used here (its lowest key is U+00A3), so probe the hash only for
          # non-ASCII cells — ASCII text and spaces, the vast majority, skip it
          # entirely. The single result is reused below instead of re-looked-up.
          acs_char = (alt_charset && !broken_acs && desired_char > '~') ? acscr[desired_char]? : nil
          if alt_charset && !broken_acs && (acs_char || acs)
            # Even without checking tput.brokenACS, the linux console would still
            # work fine since its acs table fails tput.features.acscr[desired_char].
            if ac = acs_char
              if acs
                desired_char = ac
              else
                # Avoid the (blessed-style) approach of turning char into a string
                # with the sm/rm escape prepended (`String.new(smacs) + acscr[...]`).
                # Instead, print smacs into outbuf directly and just set char to the
                # desired char — it gets printed at the end of the loop as usual.
                @outbuf.write smacs
                desired_char = ac
                acs = true
              end
            elsif acs
              # Same trick as above (write rmacs directly instead of prepending it
              # to the char string).
              @outbuf.write rmacs
              acs = false
            end
          elsif desired_char > '~'
            # The terminal couldn't render this non-ASCII glyph via ACS (no ACS,
            # or it's broken, or the glyph has no ACS mapping). U8 isn't always
            # reliable (some undeclared terminals support utf8 anyway, e.g. urxvt),
            # but a terminal declaring neither ACS nor U8 likely doesn't support
            # UTF8 either, so reducing to ASCII is the safest choice (fixes things
            # like sun-color).
            if ascii_reduce
              # Reduction of ACS into ASCII chars.
              desired_char = ascii_fallback(desired_char)
            end
          end

          # Print the cell's content. Under full_unicode: a continuation cell
          # (trailing half of a wide grapheme) emits nothing — the wide glyph
          # already advanced the cursor; a cluster cell emits its whole grapheme;
          # a wide cell claims its continuation cell, which the next iteration
          # skips (keeping cell index == terminal column).
          if fu
            # The cell's base codepoint, straight from the hoisted `chars` array
            # (`line[x]` built a second bounds-checked `Cell` handle per changed
            # cell). NOT `desired_char`, which may have been ACS-reduced above.
            base_char = l_chars.unsafe_fetch(x)
            if base_char == Cell::CONTINUATION
              # Orphan continuation cell reached WITHOUT `skip_next` (its lead was
              # unchanged and skipped, or clipped off the left edge). Nothing is
              # printed for it, so the terminal cursor did NOT advance. Force the
              # next changed cell to reposition absolutely — otherwise it would
              # assume the cursor moved and print one column too far left, shifting
              # the whole run and persisting the error into @olines (BUGS-F1
              # finding 10).
              lx = x
              ly = -1
            else
              # Fetch the grapheme overlay once and reuse it for both the emit
              # and the width below; rows with no overlay (`l_has_g` false, the
              # common case) skip the `@graphemes` probe entirely. A replacing
              # artificial cursor (`acur_glyph`) suppresses the overlay so its own
              # single-codepoint glyph is emitted here instead of the underlying
              # cluster (which would hide the cursor bar / custom glyph).
              g = (l_has_g && !acur_glyph) ? line.grapheme_at?(x) : nil
              # Equivalent to `current.width` here: the continuation case is
              # excluded by the `unless` above, so width comes from the overlay
              # cluster if present, the cursor glyph when it replaced the cell,
              # else the cell's own codepoint.
              w = g ? ::Crysterm::Unicode.width(g) : ::Crysterm::Unicode.width(acur_glyph ? desired_char : base_char)
              if g
                if ascii_reduce
                  # Non-UTF8 terminal: never emit the raw multibyte cluster (it
                  # would print several bytes for one cell). Reduce to the base
                  # codepoint's ASCII fallback, mirroring the lone-codepoint
                  # reduction above (BUGS-F1 finding 29).
                  @outbuf.print(base_char > '~' ? ascii_fallback(base_char) : base_char)
                else
                  @outbuf.print g
                end
              else
                @outbuf.print desired_char
              end
              # `o[x + 1]?` can only be nil at the last column, but a width-2 cell
              # is never placed there: `widget_rendering.cr` blanks any lead cell
              # that would lack an in-region continuation, so this claim never
              # over-runs the buffer. The nil-guard is thus defensive only.
              if w == 2 && (oc = o[x + 1]?)
                oc.attr = desired_attr
                oc.continuation!
                skip_next = true
                # A 2-column cell whose glyph was ASCII-reduced only printed ONE
                # column, but `skip_next` advances the cell index by two. Pad with
                # a space so the terminal cursor also advances two columns and
                # stays in step (BUGS-F1 finding 29).
                @outbuf.print ' ' if ascii_reduce
              end
            end
          else
            @outbuf.print desired_char
          end

          attr = desired_attr
        end

        # Reproduce the cursor-run state a full scan would leave: it would walk
        # the trailing unchanged cells (scan_hi, line_size) and, having reset `lx`
        # at the last changed cell, record the start of that trailing run. Mirrored
        # so the *next* row's reposition math matches the full scan exactly.
        # (No-op on the full-scan path, where scan_hi == line_size - 1.)
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
        # it doesn't streak across the screen as the cell runs (each prefixed by a
        # `cup`) are emitted, then restore it afterward. This MUST go straight to
        # `tput` (not `Window#hide_cursor`/`#show_cursor`): those dispatch on the
        # *active* cursor and, when it is artificial, take the artificial branch —
        # which writes no escape (leaving the hardware cursor visible and
        # streaking) and calls `render_if_active`, scheduling a redundant render
        # from *inside* `draw`. The captured sequences land in `@pre`/`@post`.
        #
        # In the `ansi_cursor` fast path the bracket sequences are the constant
        # ones cached in `DrawCaps` (`sc`/`rc`/`civis`/`cnorm`) — written straight
        # into the buffers instead of `tput.save_cursor`/… whose per-call
        # static-capability `.dup` (plus save_cursor's cursor-Point save) burned
        # ~48-80 B on EVERY output-producing frame. draw's own cursor moves are
        # raw inline ANSI here and never touch tput's software cursor tracker, so
        # the save/restore position bookkeeping is a no-op on this path and only
        # the physical bytes matter (identical to what tput would have emitted).
        # A non-conforming terminal keeps the tput (divert) path, which also
        # maintains that software cursor state.
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
        # insert/delete-line output is already folded into `@main` above, so the
        # three buffers cover everything `draw` sends this frame. Mark the frame
        # pending; `#flush_frame` performs the actual (blocking) terminal write.
        @last_draw_bytes = @pre.size + @main.size + @post.size
        @bytes_written += @last_draw_bytes
        @_frame_pending = true
      end

      # Direct callers get the terminal write inline (original contract);
      # `#_render` opts out (`flush: false`) to time it on its own.
      flush_frame if flush

      # D O:
      # emit Event::Draw
    end

    # Writes the frame `#draw` built (`@pre`+`@main`+`@post`) to the terminal.
    #
    # Split out of `#draw` so the terminal write can be timed on its own. On an
    # unbuffered tty (`Superconf.tput_use_buffer` off — the default) this is a
    # blocking `write()`; once the per-frame payload exceeds the pty buffer it
    # stalls at the terminal's refresh cadence, so it — not the diff/encode in
    # `#draw` — is where terminal backpressure shows up. A no-op when `draw`
    # produced no output this frame.
    def flush_frame : Nil
      return unless @_frame_pending
      @_frame_pending = false

      # Bracket the frame in a DEC 2026 synchronized update (when enabled) so the
      # terminal presents it atomically. Inlined into this single `_print` —
      # rather than separate begin/end calls — so the markers and the frame land
      # in one write, with no markers emitted on empty frames.
      tput._print do |io|
        io << "\e[?2026h" if synchronized_output?
        io.write @pre.to_slice
        io.write @main.to_slice
        io.write @post.to_slice
        io << "\e[?2026l" if synchronized_output?
      end
    end

    def blank_line(ch = ' ', dirty = false)
      # `Row.new awidth` only reserves capacity (size 0); the row must actually be
      # populated with `awidth` cells, otherwise blank lines inserted by
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
    # `n` times so a blank line appears at `insert_at` and the line at `delete_at`
    # falls off. The two directions differ only in which of the two indices is the
    # insert and which is the delete.
    #
    # Rather than allocating two fresh `blank_line`s (4 backing arrays) per shifted
    # line and discarding two good rows (D2), the evicted row is *recycled*: delete
    # it, blank it in place (`clear_to`, which also drops any grapheme overlay),
    # reset its dirty range, then re-insert it. `@lines`/`@olines` stay independent
    # because each buffer only ever recycles its own evicted row.
    #
    # Delete-first changes the index arithmetic vs. the original insert-then-delete:
    # `insert(I); delete(D)` removes the *pre-insert* element at `D` (if `D < I`) or
    # `D - 1` (if `D > I`), and lands the blank at `I` (if the removal was above `I`)
    # or `I - 1` (if below). These indices are constant across all `n` iterations
    # (each iteration is size-neutral), so they're computed once.
    private def shift_lines(n, insert_at, delete_at)
      removed = delete_at < insert_at ? delete_at : delete_at - 1
      final_insert = removed < insert_at ? insert_at - 1 : insert_at
      n.times do
        recycle_shifted_row @lines, removed, final_insert
        recycle_shifted_row @olines, removed, final_insert
      end
    end

    # Evicts the row at `removed_at` from `buf`, blanks it to the current screen
    # width (rebuilding cell count if the screen resized since the row was built),
    # and re-inserts it at `insert_at`. See `#shift_lines` for the index math.
    private def recycle_shifted_row(buf : Array(Row), removed_at : Int32, insert_at : Int32) : Nil
      row = buf.delete_at removed_at
      aw = awidth
      # Match the current width if the screen resized since this row was built
      # (`blank_line` always sized to `awidth`).
      while row.size > aw
        row.pop
      end
      # Blank the existing cells (also drops any grapheme overlay).
      row.clear_to @default_attr, ' '
      while row.size < aw
        row.push @default_attr, ' '
      end
      # A blank shifted line is not dirty (the terminal's own il/dl scrolled it);
      # this also resets the dirty column range.
      row.dirty = false
      buf.insert insert_at, row
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

      off = render_row_offset
      divert(@tmpbuf, @_buf) do |buf|
        tput.set_scroll_region(top + off, bottom + off)
        yield buf
        # Restore the full screen. In alt mode (`off == 0`) that IS the
        # surface's own bounds. An inline surface must NOT leave DECSTBM
        # pinned to its band: `scroll_terminal_up` (auto-grow) emits newlines
        # at the terminal's last row, which sits below the band's bottom, so a
        # pinned region made the next autogrow scroll a no-op (or scroll only
        # the band), desyncing `render_row_offset` and painting over shell
        # history.
        tput.set_scroll_region(0, (@alternate ? aheight : tput.screen.height) - 1)
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
    def insert_line_nc(n, y, top, bottom)
      return unless with_scroll_region(top, bottom) do
                      tput.cup(top + render_row_offset, 0)
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
      # Only emits `dl` (delete_line), so it needs change-scroll-region +
      # delete_line — not insert_line. Requiring `il` here would make `delete_line`
      # a silent no-op (dropping the buffer-side `shift_lines_up` too) on terminals
      # that advertise CSR + delete_line but not insert_line.
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
    def delete_line_nc(n, y, top, bottom)
      # XXX temporarily diverts output
      return unless with_scroll_region(top, bottom) do |ret|
                      tput.cup(bottom + render_row_offset, 0)
                      # Emit `n` newlines without materializing a throwaway
                      # `"\n" * n` String per CSR scroll op (D3).
                      n.times { ret << '\n' }
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

    # Checks whether an element has uniform cells on both sides; if so, CSR can
    # be used to optimize scrolling on a scrollable element. Not exactly sure
    # how worthwhile this is — it costs CPU, but maybe less than slow-rendering
    # scrollable boxes with clean sides would.
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
    # scrollable element). Each row's cell is compared against the reference cell
    # taken from the top row (`@olines[yi]`); the first mismatch returns false. A
    # row missing the column stops the scan early, and a missing top row leaves
    # the reference cell nil so the scan breaks before any comparison.
    private def column_uniform?(x, yi, yl) : Bool
      first = @olines[yi]?.try &.[x]?
      yi.upto(yl - 1) do |y|
        row = @olines[y]?
        break unless row && (ch = row[x]?)
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
    # `#draw` diffs `@lines` (this frame) against `@olines` (what's on the
    # terminal) and skips unchanged cells. But a widget drawing *outside* the
    # cell model — e.g. `Widget::Media::Overlay`'s w3m image, painted on top of
    # the terminal — needs the cells underneath a stale overlay to be physically
    # re-emitted so text redraws over it. Poisoning `@olines` here makes the
    # diff treat those cells as changed.
    def invalidate_region(xi, xl, yi, yl)
      # This pokes `@olines` outside the cell model (a w3m image overlay), which
      # the selective path can't reason about — force the full path instead.
      note_effect

      xi = 0 if xi < 0
      yi = 0 if yi < 0

      yi.upto(yl - 1) do |y|
        oline = @olines[y]?
        break unless oline

        line = @lines[y]?

        # The poison sentinel '\0' equals `Cell::CONTINUATION`: when the
        # rect's LEFT edge lands on the trailing half of a wide grapheme, the
        # desired cell is *also* '\0' with the same attr, compares unchanged,
        # and is skipped — the wide glyph straddling the edge would never be
        # repainted. Widen the poison one column left so the LEAD cell is
        # re-emitted (which re-claims its continuation).
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

    # Walks every existing cell of the rectangular region `[xi, xl) × [yi, yl)`
    # in `@lines`, yielding each cell together with its line. A row's scan stops
    # at the first missing cell and the whole walk stops at the first missing
    # row. With `clamp` (the default) a negative `xi`/`yi` origin is pulled back
    # to 0; the shadow/blend callers pass their bounds verbatim with `clamp: false`.
    #
    # A negative index is treated as off the top/left of the grid and SKIPPED
    # (row/column 0 onward is still visited). This must be explicit: Crystal's
    # `Array#[]?`/`Indexable#[]?` count a negative index *from the end*
    # (`@lines[-1]?` is the last row, not `nil`), so a `clamp: false` caller
    # passing a negative origin — exactly what a widget's top/left shadow does
    # against the top/left screen edge (`yi - s.top`, `xi - s.left`) — would
    # otherwise wrap around and blend the shadow band onto the OPPOSITE
    # (bottom/right) edge. Off the bottom/right (index >= size) correctly
    # yields `nil` and breaks.
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
    # width once and indexes with `unsafe_fetch`/`unsafe_put` — the same
    # array-hoist `draw` uses — instead of a `Cell` handle and bounds-checked
    # `line[x]?` per cell. `xi`/`yi` are clamped to >= 0 (matching
    # `each_region_cell`), and cells are contiguous, so a cell is "missing" only
    # when `x` runs past the row end (`xend`); every `unsafe_*` is provably in range.
    #
    # For a *scattered* single cell (e.g. a dial pointer, a spaced slider tick)
    # where there is no contiguous run to batch, call this with a 1x1 region
    # (`fill_region attr, ch, x, x + 1, y, y + 1`): it change-guards the write and
    # narrows the dirty range to that one column.
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
        # Most rows have none in this per-frame full-screen clear path, so
        # skipping the per-cell `grapheme_at?`/`delete_grapheme` calls (overhead
        # that dominated the render profile) on those rows is a real win.
        has_g = line.has_graphemes?
        # Same hoist for the hyperlink overlay: `Cell#char=`'s invariant is
        # that every content write clears the cell's link, and this raw-array
        # writer must uphold it — otherwise blanked cells kept their old link
        # ids and were re-emitted wrapped in stale OSC 8 (an invisible
        # clickable region), with the row permanently `has_links?`.
        has_l = line.has_links?

        x = xi
        while x < xend
          # Equivalent to `cell != {attr, ch}` (see `Cell#==(Tuple)`): a cell
          # carrying a grapheme overlay is never equal to a single-char tuple, so
          # it must be rewritten. The `||` short-circuits exactly as `==` does;
          # the `grapheme_at?` probe is reached only when attr/char already match
          # AND the row has some overlay (`has_g`), so overlay-free rows never
          # call it. A cell carrying a link must be rewritten too, or an
          # already-blank linked cell would be skipped with its link intact.
          if override || attrs.unsafe_fetch(x) != attr || chars.unsafe_fetch(x) != ch ||
             (has_g && !line.grapheme_at?(x).nil?) || (has_l && line.link_at(x) != 0_u16)
            attrs.unsafe_put(x, attr)
            chars.unsafe_put(x, ch)
            # Mirrors `Cell#char=`, which drops any cluster overlay on the cell —
            # only needed when the row actually carries one.
            line.delete_grapheme(x) if has_g
            # ...and the link overlay (the other `Cell#char=` side effect).
            line.delete_link(x) if has_l
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
    # With *glyph* set (a half-block such as `▀`/`▄`/`▌`/`▐`), the band is painted
    # with that character instead of darkening the whole cell, so only part of the
    # cell reads as shadow — a thin shadow that escapes the terminal's ~2:1 cell
    # aspect ratio (see `Shadow`'s glyph fields).
    #
    # The shadow tone is carried by the cell's *background*, not the glyph's
    # foreground: a background is a solid fill that reaches the cell edges, whereas
    # a foreground half-block can leave a hairline gap at the top/side in some
    # fonts. The glyph's foreground instead paints the untouched backdrop over the
    # complementary half. So pick the glyph whose *solid* half faces AWAY from the
    # widget: `▄` shadows the top half (bottom-edge shadow), `▀` the bottom, `▐`
    # the left half (right-edge shadow), `▌` the right.
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
