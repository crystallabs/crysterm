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

      if @_buf.size > 0
        @main.print @_buf
        @_buf.clear
      end

      ::Log.trace { "Drawing #{start}..#{stop}" }

      c = cursor

      # For all rows (y = row coordinate)
      (start..stop).each do |y|
        # Current line we're looking at, which we'll possibly modify (array of cells)
        line = @lines[y]

        # Original line, as it was in the previous render
        o = @olines[y]

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

        # For all cells in row (x = column coordinate)
        line.size.times do |x|
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
          if @optimization.bce? && (desired_char == ' ') &&
             (tput.has?(&.back_color_erase?) || ((desired_attr & 0x1ff) == (@default_attr & 0x1ff))) &&
             (((desired_attr >> 18) & 8) == ((@default_attr >> 18) & 8))
            clr = true
            neq = false # Current line 'not equal' to line as it was on previous render (i.e. it changed content)

            (x...line.size).each do |xx|
              if line[xx] != {desired_attr, ' '}
                clr = false
                break
              end
              if line[xx] != o[xx]
                neq = true
              end
            end

            # Seems like this block performs clearing of a line, if it's not clear but needs to be
            if clr && neq
              lx = -1
              ly = -1
              if attr != desired_attr
                attr = desired_attr
                @outbuf.print code2attr attr
              end

              # ### XXX Temporarily diverts output. #### Needs a better solution than this.
              @tmpbuf.clear
              (tput.ret = @tmpbuf).try do |ret|
                tput.cup(y, x)
                tput.el
                @outbuf.print ret.rewind.gets_to_end
                tput.ret = nil
              end
              #### #### ####

              (x...line.size).each do |xx|
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

          # Optimize by comparing the real output
          # buffer to the pending output buffer.
          o[x]?.try do |ox|
            if ox == {desired_attr, desired_char}
              if lx == -1
                lx = x
                ly = y
              end
              next
            elsif lx != -1
              if s.parm_right_cursor?
                @outbuf.write((y == ly) ? s.cuf(x - lx) : s.cup(y, x))
              else
                @outbuf.write s.cup(y, x)
              end
              lx = -1
              ly = -1
            end
            ox.attr = desired_attr
            ox.char = desired_char
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

              bg = desired_attr & 0x1ff
              fg = (desired_attr >> 9) & 0x1ff

              flags = desired_attr >> 18
              # bold
              if (flags & 1) != 0
                @outbuf.print "1;"
              end

              # underline
              if (flags & 2) != 0
                @outbuf.print "4;"
              end

              # blink
              if (flags & 4) != 0
                @outbuf.print "5;"
              end

              # inverse
              if (flags & 8) != 0
                @outbuf.print "7;"
              end

              # invisible
              if (flags & 16) != 0
                @outbuf.print "8;"
              end

              if bg != 0x1ff
                bg = _reduce_color(bg)
                if bg < 16
                  if bg < 8
                    bg += 40
                  else # elsif (bg < 16)
                    bg -= 8
                    bg += 100
                  end
                  @outbuf << bg << ';'
                else
                  @outbuf << "48;5;" << bg << ';'
                end
              end

              if fg != 0x1ff
                fg = _reduce_color(fg)
                if fg < 16
                  if fg < 8
                    fg += 30
                  else # elsif (fg < 16)
                    fg -= 8
                    fg += 90
                  end
                  @outbuf << fg << ';'
                else
                  @outbuf << "38;5;" << fg << ';'
                end
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
            if s.enter_alt_charset_mode? && !tput.features.broken_acs? && (tput.features.acscr[desired_char]? || acs)
              # Fun fact: even if tput.brokenACS wasn't checked here,
              # the linux console would still work fine because the acs
              # table would fail the check of: tput.features.acscr[desired_char]
              if tput.features.acscr[desired_char]?
                if acs
                  desired_char = tput.features.acscr[desired_char]
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
                  desired_char = tput.features.acscr[desired_char]
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
            if !tput.features.unicode? && (tput.terminfo.try(&.extensions.get_num?("U8")) != 1) && (desired_char > '~')
              # Reduction of ACS into ASCII chars.
              desired_char = Tput::ACSC::Data[desired_char]?.try(&.[2]) || '?'
            end
          end

          # Now print the char itself.
          @outbuf.print desired_char

          attr = desired_attr
        end

        if attr != @default_attr
          @outbuf.print "\e[m"
        end

        unless @outbuf.empty?
          # STDERR.puts @outbuf.size
          @main.write s.cup(y, 0) # .to_slice)
          @main.print @outbuf.rewind.gets_to_end
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

        (tput.ret = @tmpbuf).try do |ret|
          tput.save_cursor
          if !hidden
            hide_cursor
          end

          @pre << ret.rewind.gets_to_end
          tput.ret = nil
        end

        @tmpbuf.clear

        (tput.ret = @tmpbuf).try do |ret|
          tput.restore_cursor
          if !hidden
            show_cursor
          end

          @post << ret.rewind.gets_to_end
          tput.ret = nil
        end

        # D O:
        # display.flush()
        # display._owrite(@pre + @main + @post)
        tput._print { |io| io << @pre << @main.rewind.gets_to_end << @post }
      end

      # D O:
      # emit Event::Draw
    end

    def blank_line(ch = ' ', dirty = false)
      o = Row.new awidth, {@default_attr, ch}
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

      (tput.ret = IO::Memory.new).try do |ret|
        tput.set_scroll_region(top, bottom)
        tput.cup(y, 0)
        tput.il(n)
        tput.set_scroll_region(0, aheight - 1)

        @_buf.print ret.rewind.gets_to_end
        tput.ret = nil
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

      (tput.ret = IO::Memory.new).try do |ret|
        tput.set_scroll_region(top, bottom)
        tput.cup(top, 0)
        tput.dl(n)
        tput.set_scroll_region(0, aheight - 1)

        @_buf.print ret.rewind.gets_to_end
        tput.ret = nil
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
      (tput.ret = IO::Memory.new).try do |ret|
        tput.set_scroll_region(top, bottom)
        tput.cup(y, 0)
        tput.dl(n)
        tput.set_scroll_region(0, aheight - 1)

        @_buf.print ret.rewind.gets_to_end
        tput.ret = nil
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
      (tput.ret = IO::Memory.new).try do |ret|
        tput.set_scroll_region(top, bottom)
        tput.cup(bottom, 0)
        ret.print "\n" * n
        tput.set_scroll_region(0, aheight - 1)

        @_buf.print ret.rewind.gets_to_end
        tput.ret = nil
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
        return pos._clean_sides = true if (awidth - (pos.xl - pos.xi)) < 40
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
    def clear_region(xi, xl, yi, yl, override)
      fill_region @default_attr, ' ', xi, xl, yi, yl, override
    end

    # Fills any chosen region on the screen with chosen character and attributes.
    def fill_region(attr, ch, xi, xl, yi, yl, override = false)
      lines = @lines

      xi = 0 if xi < 0
      yi = 0 if yi < 0

      yi.upto(yl - 1) do |y|
        break unless lines[y]?

        xi.upto(xl - 1) do |x|
          cell = lines[y][x]?
          break unless cell

          if override || cell != {attr, ch}
            lines[y][x].attr = attr
            lines[y][x].char = ch
            lines[y].dirty = true
          end
        end
      end
    end
  end
end
