module Crysterm
  class Screen
    # Conversion between SGR sequences and Crysterm's attribute format

    # Converts an SGR string to our own attribute format.
    def attr2code(code, cur, dfl)
      flags = (cur >> 18) & 0x1ff
      fg = (cur >> 9) & 0x1ff
      bg = cur & 0x1ff
      # c
      # i

      code = code[2...-1].split(';')
      if !code[0]? || code[0].empty?
        code[0] = "0"
      end

      # NOTE: an SGR sequence can carry several codes (e.g. `\e[1;31m` =
      # bold + red), so every code must be applied in turn. We use an explicit
      # index because the truecolor/256-color forms consume several codes at
      # once and need to advance `i` past their parameters.
      i = 0
      while i < code.size
        c = !code[i].empty? ? code[i].to_i : 0
        case c
        when 0 # normal
          bg = dfl & 0x1ff
          fg = (dfl >> 9) & 0x1ff
          flags = (dfl >> 18) & 0x1ff
        when 1 # bold
          flags |= 1
        when 22
          flags = (dfl >> 18) & 0x1ff
        when 4 # underline
          flags |= 2
        when 24
          flags = (dfl >> 18) & 0x1ff
        when 5 # blink
          flags |= 4
        when 25
          flags = (dfl >> 18) & 0x1ff
        when 7 # inverse
          flags |= 8
        when 27
          flags = (dfl >> 18) & 0x1ff
        when 8 # invisible
          flags |= 16
        when 28
          flags = (dfl >> 18) & 0x1ff
        when 39 # default fg
          fg = (dfl >> 9) & 0x1ff
        when 49 # default bg
          bg = dfl & 0x1ff
        when 38, 48 # extended fg (38) / bg (48): 256-color or truecolor
          mode = code[i + 1]?.try &.to_i
          if mode == 5 # `<38|48>;5;n` (256-color)
            color = code[i + 2]?.try(&.to_i) || 0
            c == 38 ? (fg = color) : (bg = color)
            i += 2
          elsif mode == 2 # `<38|48>;2;r;g;b` (truecolor)
            color = Colors.match(
              code[i + 2]?.try(&.to_i) || 0,
              code[i + 3]?.try(&.to_i) || 0,
              code[i + 4]?.try(&.to_i) || 0)
            if c == 38
              fg = color == -1 ? (dfl >> 9) & 0x1ff : color
            else
              bg = color == -1 ? dfl & 0x1ff : color
            end
            i += 4
          end
        else # 8/16-color fg/bg, including bright variants
          if c >= 40 && c <= 47
            bg = c - 40
          elsif c >= 100 && c <= 107 # bright bg (100 = bright black bg, not "default")
            bg = c - 100
            bg += 8
          elsif c >= 30 && c <= 37
            fg = c - 30
          elsif c >= 90 && c <= 97 # bright fg
            fg = c - 90
            fg += 8
          end
        end
        i += 1
      end

      (flags << 18) | (fg << 9) | bg
    end

    # Converts our own attribute format to an SGR string.
    def code2attr(code)
      flags = (code >> 18) & 0x1ff
      fg = (code >> 9) & 0x1ff
      bg = code & 0x1ff

      String.build do |outbuf|
        outbuf << "\e["

        # bold
        outbuf << "1;" if (flags & 1) != 0

        # underline
        outbuf << "4;" if (flags & 2) != 0

        # blink
        outbuf << "5;" if (flags & 4) != 0

        # inverse
        outbuf << "7;" if (flags & 8) != 0

        # invisible
        outbuf << "8;" if (flags & 16) != 0

        if bg != 0x1ff
          bg = _reduce_color(bg)
          if bg < 16
            bg < 8 ? outbuf << (bg + 40) << ';' : outbuf << (bg - 8 + 100) << ';'
          else
            outbuf << "48;5;" << bg << ';'
          end
        end

        if fg != 0x1ff
          fg = _reduce_color(fg)
          if fg < 16
            fg < 8 ? outbuf << (fg + 30) << ';' : outbuf << (fg - 8 + 90) << ';'
          else
            outbuf << "38;5;" << fg << ';'
          end
        end

        # If bytesize is 2, which is what we started with, it means nothing
        # was written, so we should in fact return an empty string.
        return "" if outbuf.bytesize == 2

        # Otherwise, something was written to the string. Since we know the
        # last char is ";", we go back one char and replace it with 'm',
        # then return that string.
        outbuf.back 1
        outbuf << 'm'
      end
    end

    # Appends the SGR sequence for `code` straight into `outbuf`, with no
    # intermediate `String` allocation.
    #
    # This is the hot-path twin of `code2attr(code)` above: the draw loop needs
    # the escape sequence written into its line buffer, and going through the
    # `String`-returning version allocates (and immediately discards) a `String`
    # every time the attribute changes. Mirrors the inline encoding already used
    # in `screen_drawing`'s main per-cell loop.
    def code2attr(code, outbuf : IO::Memory) : Nil
      flags = (code >> 18) & 0x1ff
      fg = (code >> 9) & 0x1ff
      bg = code & 0x1ff

      # Emit nothing when there are no flags and both colors are default
      # (0x1ff) — same as the `String` version returning "".
      return if flags == 0 && fg == 0x1ff && bg == 0x1ff

      outbuf << "\e["

      outbuf << "1;" if (flags & 1) != 0
      outbuf << "4;" if (flags & 2) != 0
      outbuf << "5;" if (flags & 4) != 0
      outbuf << "7;" if (flags & 8) != 0
      outbuf << "8;" if (flags & 16) != 0

      if bg != 0x1ff
        bg = _reduce_color(bg)
        if bg < 16
          bg < 8 ? outbuf << (bg + 40) << ';' : outbuf << (bg - 8 + 100) << ';'
        else
          outbuf << "48;5;" << bg << ';'
        end
      end

      if fg != 0x1ff
        fg = _reduce_color(fg)
        if fg < 16
          fg < 8 ? outbuf << (fg + 30) << ';' : outbuf << (fg - 8 + 90) << ';'
        else
          outbuf << "38;5;" << fg << ';'
        end
      end

      # At least one component above wrote a trailing ';'. Replace it with 'm'
      # by seeking back one byte and overwriting (same trick as the main loop).
      outbuf.seek -1, IO::Seek::Current
      outbuf << 'm'
    end
  end
end
