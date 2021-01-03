module Crysterm::Widget
  class Element < Node
    module Content

      class CLines
        property string = ""
        def size
          string.size
        end
        property mwidth = 0
        property width = 0
        property content = ""
        def attr=(arg)
          ""
        end
        def attr
          ""
        end
        def join(delim)
          @content
        end
        property ci = [] of Int32
        def initialize(content : String? = nil)
          @content = content
        end
      end

      property _clines = CLines.new

      def set_content(content = "", no_clear=false, no_tags=false)
        clear_pos unless no_clear
        @content = content
        parse_content(no_tags)
        #emit(SetContentEvent)
      end
      def get_content
        return "" unless @_clines
        @_clines.fake.join "\n"
      end

      def parse_content(no_tags=true)
        return false if detached?
        Log.trace { "Element not detached; parsing content: #{@content}" }

        width = @width - @iwidth
        if (@_clines.nil? ||
            @_clines.width != width ||
            @_clines.content != @content)
          content = @content

          content = content.try { |content|
              content.gsub(/[\x00-\x08\x0b-\x0c\x0e-\x1a\x1c-\x1f\x7f]/, "")
              .gsub(/\x1b(?!\[[\d;]*m)/, "")
              .gsub(/\r\n|\r/, "\n")
              .gsub(/\t/, @screen.tabc)
            }
          Log.trace { "Internal content is #{content}" }

          if true #(@screen.full_unicode)
            # double-width chars will eat the next char after render. create a
            # blank character after it so it doesn't eat the real next char.
            # TODO
            #content = content.replace(unicode.chars.all, '$1\x03')

            # iTerm2 cannot render combining characters properly.
            if @screen.program.tput.emulator.iterm2?
              # TODO
              #content = content.replace(unicode.chars.combining, "")
            end
          else
            # no double-width: replace them with question-marks.
            # TODO
            #content = content.gsub unicode.chars.all, "??"
            # delete combining characters since they're 0-width anyway.
            # NOTE: We could drop this, the non-surrogates would get changed to ? by
            # the unicode filter, and surrogates changed to ? by the surrogate
            # regex. however, the user might expect them to be 0-width.
            # NOTE: Might be better for performance to drop!
            # TODO
            #content = content.replace(unicode.chars.combining, '')
            # no surrogate pairs: replace them with question-marks.
            # TODO
            #content = content.replace(unicode.chars.surrogate, '?')
            # XXX Deduplicate code here:
            # content = helpers.dropUnicode(content)
          end

          if !no_tags
            content = _parse_tags content
          end
          Log.trace { "After _parse_tags: #{content}" }

          @_clines = _wrap_content(content, width)
          @_clines.width = width
          @_clines.content = @content
          @_clines.attr = _parse_attr @_clines
          @_clines.ci = [] of Int32
          # TODO
          #@_clines.reduce(function(total, line) do
          #  @_clines.ci.push(total)
          #  return total + line.length + 1
          #endbind(self), 0)

          @_pcontent = @_clines.join "\n"
          Log.trace { @_pcontent }
          Log.trace { "#{@width} x #{@height}" }
          #@emit ParsedContentEvent

          return true
        end

        # Need to calculate this every time because the default fg/bg may change.
        @_clines.attr = _parse_attr(@_clines) || @_clines.attr

        false
      end

      # Convert `{red-fg}foo{/red-fg}` to `\x1b[31mfoo\x1b[39m`.
      def _parse_tags(text)
        text
      end

      def _parse_attr(lines)
        Array.new(lines.size, "")
      end

      def _wrap_content(content, width)
        CLines.new content
      end

      def set_text(content="", no_clear=false)
        content = content.gsub /\x1b\[[\d;]*m/, ""
        set_content content, no_clear, true
      end
      def get_text
        get_content.gsub /\x1b\[[\d;]*m/, ""
      end

      def insert_line(i, line)
        if (line.is_a? String)
          line = line.split("\n")
        end

        if (i != i || i.nil?)
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
        #diff
        #real

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
          if (!pos)
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

      def delete_line(i, n=1)
        n = n

        if (i != i || i.nil?)
          i = @_clines.ftor.size - 1
        end

        i = Math.max(i, 0)
        i = Math.min(i, @_clines.ftor.size - 1)

        # NOTE: Could possibly compare the first and last ftor line numbers to see
        # if they"re the same, or if they fit in the visible region entirely.
        start = @_clines.size
        #diff
        real = @_clines.ftor[i][0]

        while (n>0)
          n -= 1
          @_clines.fake.splice(i, 1)
        end

        set_content(@_clines.fake.join("\n"), true)

        diff = start - @_clines.size

        # XXX clear_pos() without diff statement?
        height = 0

        if (diff > 0)
          pos = _get_coords
          if (!pos or pos==0)
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

        n = n || 1

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

      def get_lines()
        @_clines.fake #.to_a? / .split "\n" ?
      end

      def get_screen_lines()
        @_clines #.to_a? / .split "\n" ?
      end

      def str_width(text)
        #text = parse_tags ? helpers.strip_tags(text) : text
        #return @screen.full_unicode ? unicode.str_width(text) : helpers.drop_unicode(text).size
        text = text
        text.size # or bytesize?
      end

    end
  end
end
