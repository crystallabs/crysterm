module Crysterm
  class Element < Node
    module Content
      class ::String
        property attr = [] of Int32
      end

      class CLines < Array(String)
        property string = ""
        property mwidth = 0
        property width = 0
        property content = ""
        property real = [] of String

        property fake = [] of String

        property ftor = [] of Array(Int32)
        property rtof = [] of Int32
        property ci = [] of Int32

        property attr : Array(Int32)? = [] of Int32

        property ci = [] of Int32
      end

      property _clines = CLines.new

      def set_content(content = "", no_clear = false, no_tags = false)
        clear_pos unless no_clear
        @content = content
        parse_content(no_tags)
        emit(SetContentEvent)
      end

      def get_content
        return "" unless @_clines || @_clines.empty? # XXX leave only .empty?
        @_clines.fake.join "\n"
      end

      def parse_content(no_tags = false)
        return false if detached?

        Log.trace { "Element not detached; parsing content: #{@content.inspect}" }

        width = @width - @iwidth
        if (@_clines.nil? || @_clines.empty? ||
           @_clines.width != width ||
           @_clines.content != @content)
          content = @content || ""

          content =
            content.gsub(/[\x00-\x08\x0b-\x0c\x0e-\x1a\x1c-\x1f\x7f]/, "")
              .gsub(/\x1b(?!\[[\d;]*m)/, "")
              .gsub(/\r\n|\r/, "\n")
              .gsub(/\t/, @screen.tabc)

          Log.trace { "Internal content is #{content.inspect}" }

          if true # (@screen.full_unicode)
            # double-width chars will eat the next char after render. create a
            # blank character after it so it doesn't eat the real next char.
            # TODO
            # content = content.replace(unicode.chars.all, '$1\x03')

            # iTerm2 cannot render combining characters properly.
            if @screen.application.tput.emulator.iterm2?
              # TODO
              # content = content.replace(unicode.chars.combining, "")
            end
          else
            # no double-width: replace them with question-marks.
            # TODO
            # content = content.gsub unicode.chars.all, "??"
            # delete combining characters since they're 0-width anyway.
            # NOTE: We could drop this, the non-surrogates would get changed to ? by
            # the unicode filter, and surrogates changed to ? by the surrogate
            # regex. however, the user might expect them to be 0-width.
            # NOTE: Might be better for performance to drop!
            # TODO
            # content = content.replace(unicode.chars.combining, '')
            # no surrogate pairs: replace them with question-marks.
            # TODO
            # content = content.replace(unicode.chars.surrogate, '?')
            # XXX Deduplicate code here:
            # content = helpers.dropUnicode(content)
          end

          if !no_tags
            content = _parse_tags content
          end
          Log.trace { "After _parse_tags: #{content.inspect}" }

          @_clines = _wrap_content(content, width)
          @_clines.width = width
          @_clines.content = @content
          @_clines.attr = _parse_attr @_clines
          @_clines.ci = [] of Int32
          @_clines.reduce(0) do |total, line|
            @_clines.ci.push(total)
            total + line.size + 1
          end

          @_pcontent = @_clines.join "\n"
          emit ParsedContentEvent

          true
        end

        # Need to calculate this every time because the default fg/bg may change.
        @_clines.attr = _parse_attr(@_clines) || @_clines.attr

        false
      end

      # Convert `{red-fg}foo{/red-fg}` to `\x1b[31mfoo\x1b[39m`.
      def _parse_tags(text)
        if (!@parse_tags)
          return text
        end
        unless (text =~ /{\/?[\w\-,;!#]*}/)
          return text
        end

        outbuf = ""
        # state

        bg = [] of String
        fg = [] of String
        flag = [] of String

        cap = nil
        # slash
        # param
        # attr
        esc = nil

        loop do
          if (!esc && (cap = text.match /^{escape}/))
            text = text[cap[0].size..]
            esc = true
            next
          end

          if (esc && (cap = text.match /^([\s\S]+?){\/escape}/))
            text = text[cap[0].size..]
            outbuf += cap[1]
            esc = false
            next
          end

          if (esc)
            # raise "Unterminated escape tag."
            outbuf += text
            break
          end

          if (cap = text.match /^{(\/?)([\w\-,;!#]*)}/)
            text = text[cap[0].size..]
            slash = (cap[1] == '/')
            param = (cap[2].gsub(/-/, ' '))

            if (param == "open")
              outbuf += '{'
              next
            elsif (param == "close")
              outbuf += '}'
              next
            end

            if (param[-3..] == " bg")
              state = bg
            elsif (param[-3..] == " fg")
              state = fg
            else
              state = flag
            end

            if (slash)
              if (!param)
                outbuf += @screen.application.tput._attr("normal")
                bg.clear
                fg.clear
                flag.clear
              else
                attr = @screen.application.tput._attr(param, false)
                attr = nil
                if (attr.nil?)
                  outbuf += cap[0]
                else
                  # D O:
                  # if (param !== state[state.size - 1])
                  #   throw new Error('Misnested tags.')
                  # }
                  state.pop
                  if (state.size > 0)
                    outbuf += @screen.application.tput._attr(state[state.size - 1])
                  else
                    outbuf += attr
                  end
                end
              end
            else
              if (!param)
                outbuf += cap[0]
              else
                attr = @screen.application.tput._attr(param)
                if (attr.nil?)
                  outbuf += cap[0]
                else
                  state.push(param)
                  outbuf += attr
                end
              end
            end

            next
          end

          if (cap = text.match /^[\s\S]+?(?={\/?[\w\-,;!#]*})/)
            text = text[cap[0].size..]
            outbuf += cap[0]
            next
          end

          outbuf += text
          break
        end

        return outbuf
      end

      def _parse_attr(lines)
        dattr = sattr(@style)
        attr = dattr
        attrs = [] of Int32
        # line
        # i
        # j
        # c

        if (lines[0].attr == attr)
          return
        end

        (0...lines.size).each do |j|
          line = lines[j]
          attrs.push attr
          unless attrs.size == j + 1
            raise "indexing error"
          end
          (0...line.size).each do |i|
            if (line[i] == "\x1b")
              if (c = line[1..].match /^\x1b\[[\d;]*m/)
                attr = @screen.attr_code(c[0], attr, dattr)
                i += c[0].size - 1
              end
            end
          end
          j += 1
        end

        return attrs
      end

      def _wrap_content(content, width)
        tags = @parse_tags
        state = @align
        wrap = @wrap
        margin = 0
        rtof = [] of Int32
        ftor = [] of Array(Int32)
        # outbuf = [] of String
        outbuf = CLines.new
        no = 0
        # line
        # align
        # cap
        # total
        # i
        # part
        # j
        # lines
        # rest

        lines = content.split "\n"

        if !content || content.empty?
          ret = CLines.new
          ret.push(content)
          ret.rtof = [0]
          ret.ftor = [[0]]
          ret.fake = lines
          ret.real = outbuf
          ret.mwidth = 0
          return ret
        end

        if (@scrollbar)
          margin += 1
        end
        if is_a? TextArea
          margin += 1
        end
        if (width > margin)
          width -= margin
        end

        #      main:
        while no < lines.size
          line = lines[no]
          align = state

          ftor.push([] of Int32)

          # Handle alignment tags.
          if (tags)
            if (cap = line.match /^{(left|center|right)}/)
              line = line[cap[0].size..]
              align = state = (cap[1] != "left") ? cap[1] : nil
            end
            if (cap = line.match /{\/(left|center|right)}$/)
              line = line[0..(line.size - cap[0].size)]
              # state = null
              state = @align
            end
          end

          # If the string is apparently too long, wrap it.
          loop_ret = while (line.size > width)
            # Measure the real width of the string.
            total = 0
            i = 0
            while i < line.size
              while (line[i] == "\x1b")
                while (line[i] && line[i] != 'm')
                  i += 1
                end
              end
              if (line[i]?.nil?)
                break
              end
              total += 1
              if (total == width)
                # If we're not wrapping the text, we have to finish up the rest of
                # the control sequences before cutting off the line.
                i += 1
                if (!wrap)
                  rest = line[i..].scan(/\x1b\[[^m]*m/)
                  rest = rest.any? ? rest.join : ""
                  outbuf.push(_align(line[0...i] + rest, width, align))
                  ftor[no].push(outbuf.size - 1)
                  rtof.push(no)
                  break :main
                end
                # XXX
                # if (!screen.fullUnicode)
                # Try to find a space to break on.
                if (i != line.size)
                  j = i
                  while (j > i - 10 && j > 0 && (j -= 1) && line[j] != " ")
                    if (line[j] == " ")
                      i = j + 1
                    end
                  end
                end
                # end
                break
              end
              i += 1
            end

            part = line[0...i]
            line = line[i..]

            outbuf.push(_align(part, width, align))
            ftor[no].push(outbuf.size - 1)
            rtof.push(no)

            # Make sure we didn't wrap the line to the very end, otherwise
            # we get a pointless empty line after a newline.
            if (line == "")
              break :main
            end

            # If only an escape code got cut off, at it to `part`.
            if (line.match /^(?:\x1b[\[\d;]*m)+$/)
              outbuf[outbuf.size - 1] += line
              break :main
            end
          end

          if loop_ret == :main
            next
          end

          outbuf.push(_align(line, width, align))
          ftor[no].push(outbuf.size - 1)
          rtof.push(no)

          no += 1
        end

        outbuf.rtof = rtof
        outbuf.ftor = ftor
        outbuf.fake = lines
        outbuf.real = outbuf

        outbuf.mwidth = outbuf.reduce(0) do |current, line|
          line = line.gsub(/\x1b\[[\d;]*m/, "")
          # XXX Does it need explicit addition to `current`?
          line.size > current ? line.size : current
        end

        return outbuf
      end

      def set_text(content = "", no_clear = false)
        content = content.gsub /\x1b\[[\d;]*m/, ""
        set_content content, no_clear, true
      end

      def get_text
        get_content.gsub /\x1b\[[\d;]*m/, ""
      end

      def insert_line(i = nil, line = "")
        if (line.is_a? String)
          line = line.split("\n")
        end

        if (i.nil?)
          i = @_clines.ftor.size
        end

        i = Math.max(i, 0)

        while (@_clines.fake.size < i)
          @_clines.fake.push("")
          @_clines.ftor.push([@_clines.push("").size - 1])
          @_clines.rtof(@_clines.fake.size - 1)
        end

        # NOTE: Could possibly compare the first and last ftor line numbers to see
        # if they"re the same, or if they fit in the visible region entirely.
        start = @_clines.size
        # diff
        # real

        if (i >= @_clines.ftor.size)
          real = @_clines.ftor[@_clines.ftor.size - 1]
          real = real[real.size - 1] + 1
        else
          real = @_clines.ftor[i][0]
        end

        line.size.times do |j|
          @_clines.fake.insert(i + j, line[j])
        end

        set_content(@_clines.fake.join("\n"), true)

        diff = @_clines.size - start

        if (diff > 0)
          pos = _get_coords
          if (!pos || pos == 0)
            return
          end

          height = pos.yl - pos.yi - @iheight
          base = @child_base || 0
          visible = real >= base && real - base < height

          if (pos && visible && @screen.clean_sides(self))
            @screen.insert_line(diff,
              pos.yi + @itop + real - base,
              pos.yi,
              pos.yl - @ibottom - 1)
          end
        end
      end

      def delete_line(i = nil, n = 1)
        n = n

        if (i.nil?)
          i = @_clines.ftor.size - 1
        end

        i = Math.max(i, 0)
        i = Math.min(i, @_clines.ftor.size - 1)

        # NOTE: Could possibly compare the first and last ftor line numbers to see
        # if they"re the same, or if they fit in the visible region entirely.
        start = @_clines.size
        # diff
        real = @_clines.ftor[i][0]

        while (n > 0)
          n -= 1
          @_clines.fake.delete_at i
        end

        set_content(@_clines.fake.join("\n"), true)

        diff = start - @_clines.size

        # XXX clear_pos() without diff statement?
        height = 0

        if (diff > 0)
          pos = _get_coords
          if (!pos || pos == 0)
            return
          end

          height = pos.yl - pos.yi - @iheight

          base = @child_base || 0
          visible = real >= base && real - base < height

          if (pos && visible && @screen.clean_sides(self))
            @screen.delete_line(diff,
              pos.yi + @itop + real - base,
              pos.yi,
              pos.yl - @ibottom - 1)
          end
        end

        if (@_clines.size < height)
          clear_pos()
        end
      end

      def insert_top(line)
        fake = @_clines.rtof[@child_base || 0]
        insert_line(fake, line)
      end

      def insert_bottom(line)
        h = (@child_base || 0) + @height - @iheight
        i = Math.min(h, @_clines.size)
        fake = @_clines.rtof[i - 1] + 1

        insert_line(fake, line)
      end

      def delete_top(n)
        fake = @_clines.rtof[@child_base || 0]
        delete_line(fake, n)
      end

      def delete_bottom(n)
        h = (@child_base || 0) + @height - 1 - @iheight
        i = Math.min(h, @_clines.size - 1)
        fake = @_clines.rtof[i]

        n = 1 if !n || n == 0

        delete_line(fake - (n - 1), n)
      end

      def set_line(i, line)
        i = Math.max(i, 0)
        while (@_clines.fake.size < i)
          @_clines.fake.push("")
        end
        @_clines.fake[i] = line
        set_content(@_clines.fake.join("\n"), true)
      end

      def set_baseline(i, line)
        fake = @_clines.rtof[@child_base || 0]
        set_line(fake + i, line)
      end

      def get_line(i)
        i = Math.max(i, 0)
        i = Math.min(i, @_clines.fake.size - 1)
        @_clines.fake[i]
      end

      def get_baseline(i)
        fake = @_clines.rtof[@child_base || 0]
        get_line(fake + i)
      end

      def clear_line(i)
        i = Math.min(i, @_clines.fake.size - 1)
        set_line(i, "")
      end

      def clear_base_line(i)
        fake = @_clines.rtof[@child_base || 0]
        clear_line(fake + i)
      end

      def unshift_line(line)
        insert_line(0, line)
      end

      def shift_line(n)
        delete_line(0, n)
      end

      def push_line(line)
        if (!@content)
          return set_line(0, line)
        end
        insert_line(@_clines.fake.size, line)
      end

      def pop_line(n)
        delete_line(@_clines.fake.size - 1, n)
      end

      def get_lines
        @_clines.fake.dup
      end

      def get_screen_lines
        @_clines.dup
      end

      def str_width(text)
        text = @parse_tags ? helpers.strip_tags(text) : text
        # return @screen.full_unicode ? unicode.str_width(text) : helpers.drop_unicode(text).size
        # text = text
        text.size # or bytesize?
      end
    end
  end
end
