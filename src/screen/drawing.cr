module Crysterm
  class Screen
    # Things related to drawing (displaying rendered state to display)
    module Drawing
      @outbuf : IO::Memory = IO::Memory.new 10_240
      @main : IO::Memory = IO::Memory.new 10_240

      @pre = IO::Memory.new 1024
      @post = IO::Memory.new 1024

      # Draws the screen based on the contents of the output buffer.
      def draw(start = 0, stop = @lines.size - 1)
        # D O:
        # emit Event::PreDraw
        # x , y , line , out , ch , data , attr , fg , bg , flags
        # pre , post
        # clr , neq , xx
        # acs
        @main.clear
        @outbuf.clear
        lx = -1
        ly = -1
        acs = false
        s = display.tput.shim.not_nil!

        if @_buf.size > 0
          @main.print @_buf
          @_buf.clear
        end

        Log.trace { "Drawing #{start}..#{stop}" }

        (start..stop).each do |y|
          line = @lines[y]
          o = @olines[y]
          # Log.trace { line } if line.any? &.char.!=(' ')

          if (!line.dirty && !(cursor.artificial? && (y == display.tput.cursor.y)))
            next
          end
          line.dirty = false

          # Assume line is dirty by continuing: (XXX need to optimize)

          @outbuf.clear

          attr = @dattr

          line.size.times do |x|
            data = line[x].attr
            ch = line[x].char

            c = cursor
            # Render the artificial cursor.
            if (c.artificial? && !c._hidden && (c._state != 0) && (x == display.tput.cursor.x) && (y == display.tput.cursor.y))
              data, ch = _artificial_cursor_attr(c, data)
            end

            # Take advantage of xterm's back_color_erase feature by using a
            # lookahead. Stop spitting out so many damn spaces. NOTE: Is checking
            # the bg for non BCE terminals worth the overhead?
            if (@optimization.bce? && (ch == ' ') &&
               (display.tput.has?(&.back_color_erase?) || (data & 0x1ff) == (@dattr & 0x1ff)) &&
               (((data >> 18) & 8) == ((@dattr >> 18) & 8)))
              clr = true
              neq = false

              (x...line.size).each do |xx|
                if line[xx] != {data, ' '}
                  clr = false
                  break
                end
                if line[xx] != o[xx]
                  neq = true
                end
              end

              if (clr && neq)
                lx = -1
                ly = -1
                if (data != attr)
                  @outbuf.print code_attr(data)
                  attr = data
                end

                # ### Temporarily diverts output. ####
                # XXX See if it causes problems when multithreaded or something?
                (display.tput.ret = IO::Memory.new).try do |ret|
                  display.tput.cup(y, x)
                  display.tput.el
                  @outbuf.print ret.rewind.gets_to_end
                  display.tput.ret = nil
                end
                #### #### ####

                (x...line.size).each do |xx|
                  o[xx].attr = data
                  o[xx].char = ' '
                end
                break
              end

              # D O:
              # If there's more than 10 spaces, use EL regardless
              # and start over drawing the rest of line. Might
              # not be worth it. Try to use ECH if the terminal
              # supports it. Maybe only try to use ECH here.
              # #if (display.tput.strings.erase_chars)
              # if (!clr && neq && (xx - x) > 10)
              #   lx = -1; ly = -1
              #   if (data != attr)
              #     @outbuf.print code_attr(data)
              #     attr = data
              #   end
              #   @outbuf.print display.tput.cup(y, x)
              #   if (display.tput.strings.erase_chars)
              #     # Use erase_chars to avoid erasing the whole line.
              #     @outbuf.print display.tput.ech(xx - x)
              #   else
              #     @outbuf.print display.tput.el()
              #   end
              #   if (display.tput.strings.parm_right_cursor)
              #     @outbuf.print display.tput.cuf(xx - x)
              #   else
              #     @outbuf.print display.tput.cup(y, xx)
              #   end
              #   fill_region(data, ' ', x, display.tput.strings.erase_chars ? xx : line.length, y, y + 1)
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
              #     attr = data
              #     break
              #   end
              # end
            end

            # Optimize by comparing the real output
            # buffer to the pending output buffer.
            # TODO Avoid using Strings
            o[x]?.try do |ox|
              if ox == {data, ch}
                if (lx == -1)
                  lx = x
                  ly = y
                end
                next
              elsif (lx != -1)
                if (s.parm_right_cursor?)
                  @outbuf.write ((y == ly) ? s.cuf(x - lx) : s.cup(y, x))
                else
                  @outbuf.write s.cup(y, x)
                end
                lx = -1
                ly = -1
              end
              ox.attr = data
              ox.char = ch
            end

            if (data != attr)
              if (attr != @dattr)
                @outbuf.print "\e[m"
              end
              if (data != @dattr)
                @outbuf.print "\e["

                # This will keep track whether any of the attrs were
                # written into the buffer. If they were, then we'll seek
                # to (current_pos)-1 to delete the last ';'
                outbuf_size = @outbuf.size

                bg = data & 0x1ff
                fg = (data >> 9) & 0x1ff
                flags = data >> 18
                # bold
                if ((flags & 1) != 0)
                  @outbuf.print "1;"
                end

                # underline
                if ((flags & 2) != 0)
                  @outbuf.print "4;"
                end

                # blink
                if ((flags & 4) != 0)
                  @outbuf.print "5;"
                end

                # inverse
                if ((flags & 8) != 0)
                  @outbuf.print "7;"
                end

                # invisible
                if ((flags & 16) != 0)
                  @outbuf.print "8;"
                end

                if (bg != 0x1ff)
                  bg = _reduce_color(bg)
                  if (bg < 16)
                    if (bg < 8)
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

                if (fg != 0x1ff)
                  fg = _reduce_color(fg)
                  if (fg < 16)
                    if (fg < 8)
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
                # Log.trace { @outbuf.inspect }
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
            #      ch = ' '
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
            # Maybe remove !display.tput.unicode check, however,
            # this seems to be the way ncurses does it.
            #
            # Note the behavior of this IF/ELSE block. It may decide to
            # print to @outbuf certain prefix data, but after the IF/ELSE block
            # the 'ch' is always written. This logic is taken for speed. In the
            # case that the contents of the IF/ELSE block change in incompatible
            # way, this should be had in mind.
            if s
              if (s.enter_alt_charset_mode? && !display.tput.features.broken_acs? && (display.tput.features.acscr[ch]? || acs))
                # Fun fact: even if display.tput.brokenACS wasn't checked here,
                # the linux console would still work fine because the acs
                # table would fail the check of: display.tput.features.acscr[ch]
                # TODO This is nasty. Char gets changed to string
                # when sm/rm is added to the stream.
                if (display.tput.features.acscr[ch]?)
                  if (acs)
                    ch = display.tput.features.acscr[ch]
                  else
                    # sm = String.new s.smacs
                    # ch = sm + display.tput.features.acscr[ch]
                    # Instead, just print prefix and set new char:
                    @outbuf.write s.smacs
                    ch = display.tput.features.acscr[ch]

                    acs = true
                  end
                elsif acs
                  # rm = String.new s.rmacs
                  # ch = rm + ch
                  # Instead, similar as above:
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
              # if (!display.tput.unicode && ch > '~') {
              if (!display.tput.features.unicode? && (display.tput.terminfo.try(&.extensions.get_num?("U8")) != 1) && (ch > '~'))
                # Reduction of ACS into ASCII chars.
                ch = Tput::ACSC::Data[ch]?.try(&.[2]) || '?'
              end
            end

            # Now print the char itself.
            @outbuf.print ch

            attr = data
          end

          if (attr != @dattr)
            @outbuf.print "\e[m"
          end

          unless @outbuf.empty?
            # STDERR.puts @outbuf.size
            @main.write s.cup(y, 0) # .to_slice)
            @main.print @outbuf.rewind.gets_to_end
          end
        end

        if (acs)
          @main.write s.rmacs
          acs = false
        end

        unless @main.size == 0
          @pre.clear
          @post.clear
          hidden = display.tput.cursor_hidden?

          (display.tput.ret = IO::Memory.new).try do |ret|
            display.tput.save_cursor
            if !hidden
              hide_cursor
            end

            @pre << ret.rewind.gets_to_end
            display.tput.ret = nil
          end

          (display.tput.ret = IO::Memory.new).try do |ret|
            display.tput.restore_cursor
            if !hidden
              show_cursor
            end

            @post << ret.rewind.gets_to_end
            display.tput.ret = nil
          end

          # D O:
          # display.flush()
          # display._owrite(@pre + @main + @post)
          display.tput._print { |io| io << @pre << @main.rewind.gets_to_end << @post }
        end

        # D O:
        # emit Event::Draw
      end

      def blank_line(ch = ' ', dirty = false)
        o = Row.new width, {@dattr, ch}
        o.dirty = dirty
        o
      end

      # Inserts lines into the screen. (If CSR is used, it bypasses the output buffer.)
      def insert_line(n, y, top, bottom)
        # D O:
        # if (y == top)
        #  return insert_line_nc(n, y, top, bottom)
        # end

        if (!display.tput.has?(&.change_scroll_region?) ||
           !display.tput.has?(&.delete_line?) ||
           !display.tput.has?(&.insert_line?))
          STDERR.puts "Missing needed terminfo capabilities"
          return
        end

        (display.tput.ret = IO::Memory.new).try do |ret|
          display.tput.set_scroll_region(top, bottom)
          display.tput.cup(y, 0)
          display.tput.il(n)
          display.tput.set_scroll_region(0, height - 1)

          @_buf.print ret.rewind.gets_to_end
          display.tput.ret = nil
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
        if (!display.tput.has?(&.change_scroll_region?) ||
           !display.tput.has?(&.delete_line?))
          STDERR.puts "Missing needed terminfo capabilities"
          return
        end

        (display.tput.ret = IO::Memory.new).try do |ret|
          display.tput.set_scroll_region(top, bottom)
          display.tput.cup(top, 0)
          display.tput.dl(n)
          display.tput.set_scroll_region(0, height - 1)

          @_buf.print ret.rewind.gets_to_end
          display.tput.ret = nil
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

        if (!display.tput.has?(&.change_scroll_region?) ||
           !display.tput.has?(&.delete_line?) ||
           !display.tput.has?(&.insert_line?))
          STDERR.puts "Missing needed terminfo capabilities"
          return
        end

        # XXX temporarily diverts output
        (display.tput.ret = IO::Memory.new).try do |ret|
          display.tput.set_scroll_region(top, bottom)
          display.tput.cup(y, 0)
          display.tput.dl(n)
          display.tput.set_scroll_region(0, height - 1) # XXX @height should be used?

          @_buf.print ret.rewind.gets_to_end
          display.tput.ret = nil
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
        if (!display.tput.has?(&.change_scroll_region?) ||
           !display.tput.has?(&.delete_line?))
          STDERR.puts "Missing needed terminfo capabilities"
          return
        end

        # XXX temporarily diverts output
        (display.tput.ret = IO::Memory.new).try do |ret|
          display.tput.set_scroll_region(top, bottom)
          display.tput.cup(bottom, 0)
          ret.print "\n" * n
          display.tput.set_scroll_region(0, height - 1)

          @_buf.print ret.rewind.gets_to_end
          display.tput.ret = nil
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
        clear_region(0, width, bottom, bottom)
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
      # Not exactly sure how worthwile this is.
      # This will cause a performance/cpu-usage hit,
      # but will it be less or greater than the
      # performance hit of slow-rendering scrollable
      # boxes with clean sides?
      def clean_sides(el)
        pos = el.lpos

        if (!pos)
          return false
        end

        unless (pos._clean_sides.nil?)
          return pos._clean_sides
        end

        if (pos.xi <= 0 && (pos.xl >= width))
          return pos._clean_sides = true
        end

        if @optimization.fast_csr?
          # Maybe just do this instead of parsing.
          if (pos.yi < 0)
            return pos._clean_sides = false
          end
          if (pos.yl > height)
            return pos._clean_sides = false
          end
          if ((width - (pos.xl - pos.xi)) < 40)
            return pos._clean_sides = true
          end
          return pos._clean_sides = false
        end

        unless @optimization.smart_csr?
          return false
        end

        # D O:
        # The scrollbar can't update properly, and there's also a
        # chance that the scrollbar may get moved around senselessly.
        # NOTE: In pratice, this doesn't seem to be the case.
        # if @scrollbar
        #  return pos._clean_sides = false
        # end
        # Doesn't matter if we're only a height of 1.
        # if ((pos.yl - el.ibottom) - (pos.yi + el.itop) <= 1)
        #   return pos._clean_sides = false
        # end

        yi = pos.yi + el.itop
        yl = pos.yl - el.ibottom
        # first
        # ch
        # x
        # y

        if (pos.yi < 0)
          return pos._clean_sides = false
        end
        if (pos.yl > height)
          return pos._clean_sides = false
        end
        if ((pos.xi - 1) < 0)
          return pos._clean_sides = true
        end
        if (pos.xl > width)
          return pos._clean_sides = true
        end

        x = pos.xi - 1
        while x >= 0
          if (!@olines[yi]?)
            break
          end
          first = @olines[yi][x]
          (yi...yl).each do |y|
            if (!@olines[y]? || !@olines[y][x]?)
              break
            end
            ch = @olines[y][x]
            if ch != first
              return pos._clean_sides = false
            end
          end
          x -= 1
        end

        (pos.xl...width).each do |x2|
          if (!@olines[yi]?)
            break
          end
          first = @olines[yi][x2]
          (yi...yl).each do |y|
            if (!@olines[y] || !@olines[y][x2])
              break
            end
            ch = @olines[y][x2]
            if ch != first
              return pos._clean_sides = false
            end
          end
          x2 += 1
        end

        pos._clean_sides = true
      end

      # Clears any chosen region on the screen.
      def clear_region(xi, xl, yi, yl, override)
        fill_region @dattr, ' ', xi, xl, yi, yl, override
      end

      # Fills any chosen region on the screen with chosen character and attributes.
      def fill_region(attr, ch, xi, xl, yi, yl, override = false)
        lines = @lines

        if (xi < 0)
          xi = 0
        end
        if (yi < 0)
          yi = 0
        end

        while yi < yl
          break unless @lines[yi]?

          xx = xi
          while xx < xl
            cell = lines[yi][xx]?
            break unless cell

            if override || cell != {attr, ch}
              lines[yi][xx].attr = attr
              lines[yi][xx].char = ch
              lines[yi].dirty = true
            end

            xx += 1
          end
          yi += 1
        end
      end
    end
  end
end
