module Crysterm
  class Screen
    # Things related to drawing (displaying rendered state on screen)
    #
    # In general terms, "rendering" refers to refreshing an (Y,X) array of cells in memory
    # so that each has the desired cell attributes (color, bold, underline, etc.) and
    # character printed in it (if any). (Sort of like a framebuffer for the console :)
    #
    # After that step, "drawing" refers to examining the differences between the current
    # and desired state of screen, and generating a stream of plain text and embedded commands
    # (escape sequences) that is sent to the terminal that will hopefully result in
    # the screen showing the exact same picture as the in-memory representation.
    #
    # Rendering is the complicated part where everything has to be calculated and placed
    # with the right position and content in the 2D array of cells.
    # In comparison to rendering, drawing is simpler. It only deals with optimizing the commands
    # sent to the terminal, so that the transition from previous rendered state to the new one
    # is achieved in as few escape sequences as possible.

    # Any prefix we want the final buffer to have
    @_buf = IO::Memory.new

    # Final buffer of data to print to screen. Contains content and escape sequences
    # needed to make the screen look like desired by user.
    @main : IO::Memory = IO::Memory.new 10_240 * 10

    # Temporary buffer for content and escape sequences for each individual row.
    @outbuf : IO::Memory = IO::Memory.new 10_240

    # Even more temporary buffer, for parts of row.
    @tmpbuf : IO::Memory = IO::Memory.new 64

    # From rendering:
    # @lines - Grid of desired cell contents in memory, the "framebuffer"

    property _ci = -1

    @pre = IO::Memory.new 1024
    @post = IO::Memory.new 1024

    # Temporarily routes Tput's escape-sequence output into `buf` for the
    # duration of the block (Tput appends to `tput.ret` whenever it is set),
    # then copies what was produced into `dest` and clears `tput.ret`. The block
    # is yielded `buf` so it can also write to it directly (e.g. raw newlines).
    #
    # Centralizes the `(tput.ret = buf).try do |ret| … dest.write ret.to_slice;
    # tput.ret = nil end` idiom repeated across `draw`/`insert_line`/`delete_line`
    # &c. The reset now lives in an `ensure`, so a raising block can no longer
    # leave output permanently diverted (the old inline `tput.ret = nil` was
    # skipped on exception); `dest` is written only on success, matching the
    # original (which wrote before the reset inside the block).
    private def divert(buf : IO::Memory, dest : IO, & : IO::Memory ->) : Nil
      tput.ret = buf
      begin
        yield buf
        dest.write buf.to_slice
      ensure
        tput.ret = nil
      end
    end

    # Draws the screen based on the contents of in-memory grid of cells (`@lines`).
    def draw(start = 0, stop = @lines.size - 1)
      # D O:
      # emit Event::PreDraw

      @main.clear
      # @outbuf.clear # Done below, for every line (`y`)
      lx = -1
      ly = -1
      acs = false
      s = tput.shim.not_nil!

      # Terminal capabilities, the chosen color depth and the full-unicode mode
      # are all constant for the duration of a frame, so query them once here
      # instead of for every one of the (width * height) cells in the loop below.
      # `acscr` is bound so the hot ACS lookup indexes a local hash directly.
      bce_opt = @optimization.bce?
      has_bce = tput.has? &.back_color_erase?
      parm_right_cursor = s.parm_right_cursor?
      alt_charset = s.enter_alt_charset_mode?
      broken_acs = tput.features.broken_acs?
      acscr = tput.features.acscr
      term_unicode = tput.features.unicode?
      u8 = tput.terminfo.try &.extensions.get_num?("U8")
      ncolors = colors
      fu = full_unicode?

      if @_buf.size > 0
        @main.print @_buf
        @_buf.clear
      end

      ::Log.trace { "Drawing #{start}..#{stop}" }

      # The cursor that is actually drawn: the focused widget's own cursor if it
      # has one, else the screen default (see `Screen#active_cursor`).
      c = active_cursor

      # For all rows (y = row coordinate)
      (start..stop).each do |y|
        # Current line we're looking at, which we'll possibly modify (array of cells)
        line = @lines[y]

        # Original line, as it was in the previous render
        o = @olines[y]

        # Cache the row width once; it's read by the per-cell loop bound and by
        # the two BCE look-ahead/clear scans below.
        line_size = line.size

        # ::Log.trace { line } if line.any? &.char.!=(' ')

        # Skip if no change in line
        if !line.dirty && !(c.artificial? && (y == tput.cursor.y))
          next
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
        # (a previous scan proved the tail from here is not a clearable run of
        # spaces). Lets us skip re-scanning every space in a leading run, which
        # otherwise makes a "spaces then content" line O(width^2). Reset per row.
        bce_skip_until = -1

        # For all cells in row (x = column coordinate)
        line_size.times do |x|
          if skip_next
            skip_next = false
            next
          end

          # Desired attr code and char
          desired_attr = line[x].attr
          desired_char = line[x].char

          # Render the artificial cursor.
          if c.artificial? && !c._hidden && (c._state != 0) && (x == tput.cursor.x) && (y == tput.cursor.y)
            desired_attr, tmpch = _artificial_cursor_attr(c, desired_attr)
            desired_char = tmpch if tmpch
            # XXX Is this needed:
          end

          # Take advantage of xterm's back_color_erase feature by using a
          # lookahead. Stop spitting out so many damn spaces. NOTE: Is checking
          # the bg for non BCE terminals worth the overhead?
          if bce_opt && (desired_char == ' ') && (x > bce_skip_until) &&
             (has_bce || (Attr.bg(desired_attr) == Attr.bg(@default_attr))) &&
             ((Attr.flags(desired_attr) & Attr::INVERSE) == (Attr.flags(@default_attr) & Attr::INVERSE))
            clr = true
            neq = false # Current line 'not equal' to line as it was on previous render (i.e. it changed content)
            breaker = line_size

            (x...line_size).each do |xx|
              if line[xx] != {desired_attr, ' '}
                clr = false
                breaker = xx
                break
              end
              if line[xx] != o[xx]
                neq = true
              end
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
                attr = desired_attr
                # Allocation-free SGR emission straight into the line buffer;
                # `code2attr` would allocate a fresh String for every cleared
                # line, every frame (see Screen.code2attr_to).
                Screen.code2attr_to(@outbuf, attr, ncolors)
              end

              @tmpbuf.clear
              divert(@tmpbuf, @outbuf) do
                tput.cup(y, x)
                tput.el
              end

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
          if ox = o[x]?
            if ox == {desired_attr, desired_char}
              if lx == -1
                lx = x
                ly = y
              end
              next
            elsif lx != -1
              if parm_right_cursor
                @outbuf.write((y == ly) ? s.cuf(x - lx) : s.cup(y, x))
              else
                @outbuf.write s.cup(y, x)
              end
              lx = -1
              ly = -1
            end
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

              # This will keep track whether any of the attrs were written into the
              # buffer. If they were (if size in the end is greater than size
              # recorded now) then we'll seek to (current_pos)-1 to delete the last ';'
              outbuf_size = @outbuf.size

              flags = Attr.flags(desired_attr)
              @outbuf.print "1;" if (flags & Attr::BOLD) != 0
              @outbuf.print "4;" if (flags & Attr::UNDERLINE) != 0
              @outbuf.print "5;" if (flags & Attr::BLINK) != 0
              @outbuf.print "7;" if (flags & Attr::INVERSE) != 0
              @outbuf.print "8;" if (flags & Attr::INVISIBLE) != 0

              # Emit each color at the richest depth the terminal supports
              # (truecolor `38;2;r;g;b` / 256 / 16 / 8). Default colors (-1)
              # emit nothing, so the terminal's own default applies.
              n = ncolors
              bg = Attr.unpack_color(Attr.bg(desired_attr))
              fg = Attr.unpack_color(Attr.fg(desired_attr))
              if bg != -1
                Colors.sgr_color_to(@outbuf, bg, false, n)
                @outbuf << ';'
              end
              if fg != -1
                Colors.sgr_color_to(@outbuf, fg, true, n)
                @outbuf << ';'
              end

              if @outbuf.size != outbuf_size
                # Something was written to the buffer during the code above,
                # and it surely contains a ';' at the end. Conveniently remove it.
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
          if s
            if alt_charset && !broken_acs && (acscr[desired_char]? || acs)
              # Fun fact: even if tput.brokenACS wasn't checked here,
              # the linux console would still work fine because the acs
              # table would fail the check of: tput.features.acscr[desired_char]
              if acscr[desired_char]?
                if acs
                  desired_char = acscr[desired_char]
                else
                  # This method of doing it (like blessed does it) is nasty
                  # since char gets changed to string when sm/rm escape
                  # sequence is added to it:
                  # sm = String.new s.smacs
                  # desired_char = sm + tput.features.acscr[desired_char]
                  #
                  # So instead of that, print smacs into outbuf (line buffer), and
                  # just set char to the desired char, knowing that it will be
                  # printed into outbuf at the end of the loop thanks to generic code.
                  @outbuf.write s.smacs
                  desired_char = acscr[desired_char]
                  acs = true
                end
              elsif acs
                # Same trick as above, not this:
                # rm = String.new s.rmacs
                # desired_char = rm + desired_char
                # But this:
                @outbuf.write s.rmacs
                acs = false
              end
            end
          else
            # U8 is not consistently correct. Some terminfo's
            # terminals that do not declare it may actually
            # support utf8 (e.g. urxvt), but if the terminal
            # does not declare support for ACS (and U8), chances
            # are it does not support UTF8. This is probably
            # the "safest" way to do @ Should fix things
            # like sun-color.
            # Note: It could be the case that the $LANG
            # is all that matters in some cases:
            # if (!tput.unicode && desired_char > '~') {
            if !term_unicode && (u8 != 1) && (desired_char > '~')
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
              if g = current.grapheme_overlay
                @outbuf.print g
              else
                @outbuf.print desired_char
              end
              if current.width == 2 && (oc = o[x + 1]?)
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

        if attr != @default_attr
          @outbuf.print "\e[m"
        end

        unless @outbuf.empty?
          # STDERR.puts @outbuf.size
          @main.write s.cup(y, 0) # .to_slice)
          @main.write @outbuf.to_slice
        end
      end

      if acs
        @main.write s.rmacs
        acs = false
      end

      unless @main.size == 0
        @pre.clear
        @post.clear
        hidden = tput.cursor_hidden?

        @tmpbuf.clear
        divert(@tmpbuf, @pre) do
          tput.save_cursor
          hide_cursor unless hidden
        end

        @tmpbuf.clear
        divert(@tmpbuf, @post) do
          tput.restore_cursor
          show_cursor unless hidden
        end

        # D O:
        # display.flush()
        # display._owrite(@pre + @main + @post)
        tput._print { |io| io.write @pre.to_slice; io.write @main.to_slice; io.write @post.to_slice }
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

    # Inserts lines into the screen. (If CSR is used, it bypasses the output buffer.)
    def insert_line(n, y, top, bottom)
      # D O:
      # if (y == top)
      #  return insert_line_nc(n, y, top, bottom)
      # end

      if !tput.has?(&.change_scroll_region?) ||
         !tput.has?(&.delete_line?) ||
         !tput.has?(&.insert_line?)
        STDERR.puts "Missing needed terminfo capabilities"
        return
      end

      divert(IO::Memory.new, @_buf) do
        tput.set_scroll_region(top, bottom)
        tput.cup(y, 0)
        tput.il(n)
        tput.set_scroll_region(0, aheight - 1)
      end

      j = bottom + 1

      n.times do
        @lines.insert y, blank_line
        @lines.delete_at j
        @olines.insert y, blank_line
        @olines.delete_at j
      end
    end

    # Inserts lines into the screen using ncurses-compatible method. (If CSR is used, it bypasses the output buffer.)
    #
    # This is how ncurses does it.
    # Scroll down (up cursor-wise).
    # This will only work for top line deletion as opposed to arbitrary lines.
    def insert_line_nc(n, y, top, bottom)
      if !tput.has?(&.change_scroll_region?) ||
         !tput.has?(&.delete_line?)
        STDERR.puts "Missing needed terminfo capabilities"
        return
      end

      divert(IO::Memory.new, @_buf) do
        tput.set_scroll_region(top, bottom)
        tput.cup(top, 0)
        tput.dl(n)
        tput.set_scroll_region(0, aheight - 1)
      end

      j = bottom + 1

      n.times do
        @lines.insert y, blank_line
        @lines.delete_at j
        @olines.insert y, blank_line
        @olines.delete_at j
      end
    end

    # Deletes lines from the screen. (If CSR is used, it bypasses the output buffer.)
    def delete_line(n, y, top, bottom)
      # D O:
      # if (y == top)
      #   return delete_line_nc(n, y, top, bottom)
      # end

      if !tput.has?(&.change_scroll_region?) ||
         !tput.has?(&.delete_line?) ||
         !tput.has?(&.insert_line?)
        STDERR.puts "Missing needed terminfo capabilities"
        return
      end

      # XXX temporarily diverts output
      divert(IO::Memory.new, @_buf) do
        tput.set_scroll_region(top, bottom)
        tput.cup(y, 0)
        tput.dl(n)
        tput.set_scroll_region(0, aheight - 1)
      end

      # j = bottom + 1 # Unused
      while n > 0
        n -= 1
        @lines.insert y, blank_line
        @lines.delete_at y
        @olines.insert y, blank_line
        @olines.delete_at y
      end
    end

    # Deletes lines from the screen using ncurses-compatible method. (If CSR is used, it bypasses the output buffer.)
    #
    # This is how ncurses does it.
    # Scroll down (up cursor-wise).
    # This will only work for top line deletion as opposed to arbitrary lines.
    def delete_line_nc(n, y, top, bottom)
      if !tput.has?(&.change_scroll_region?) ||
         !tput.has?(&.delete_line?)
        STDERR.puts "Missing needed terminfo capabilities"
        return
      end

      # XXX temporarily diverts output
      divert(IO::Memory.new, @_buf) do |ret|
        tput.set_scroll_region(top, bottom)
        tput.cup(bottom, 0)
        ret.print "\n" * n
        tput.set_scroll_region(0, aheight - 1)
      end

      j = bottom + 1

      n.times do
        @lines.insert j, blank_line
        @lines.delete_at y
        @olines.insert j, blank_line
        @olines.delete_at y
      end
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
      clear_region(0, awidth, bottom, bottom)
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

      (pos.xi - 1).downto(0) do |x|
        first = @olines[yi][x] if @olines[yi]?
        yi.upto(yl - 1) do |y|
          break unless @olines[y]? && @olines[y][x]?
          ch = @olines[y][x]
          return pos._clean_sides = false if ch != first
        end
      end

      (pos.xl...awidth).each do |x2|
        first = @olines[yi][x2] if @olines[yi]?
        yi.upto(yl - 1) do |y|
          break unless @olines[y]? && @olines[y][x2]?
          ch = @olines[y][x2]
          return pos._clean_sides = false if ch != first
        end
      end

      pos._clean_sides = true
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
    # `Widget::Image::Overlay`, whose w3m image is an overlay painted on top of the
    # terminal — needs the cells underneath a stale overlay to be physically
    # re-emitted so the terminal redraws text over it. Poisoning `@olines` here
    # makes the diff treat those cells as changed.
    def invalidate_region(xi, xl, yi, yl)
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

        @lines[y]?.try { |line| line.dirty = true }
      end
    end

    # Fills any chosen region on the screen with chosen character and attributes.
    def fill_region(attr, ch, xi, xl, yi, yl, override = false)
      lines = @lines

      xi = 0 if xi < 0
      yi = 0 if yi < 0

      yi.upto(yl - 1) do |y|
        line = lines[y]?
        break unless line

        xi.upto(xl - 1) do |x|
          cell = line[x]?
          break unless cell

          if override || cell != {attr, ch}
            cell.attr = attr
            cell.char = ch
            line.dirty = true
          end
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
      lines = @lines

      yi.upto(yl - 1) do |y|
        line = lines[y]?
        break unless line

        xi.upto(xl - 1) do |x|
          cell = line[x]?
          break unless cell

          cell.attr = Colors.blend(cell.attr, alpha: alpha)
          line.dirty = true
        end
      end
    end
  end
end
