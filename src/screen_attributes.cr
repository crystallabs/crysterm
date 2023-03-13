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
      if (!code[0]? || code[0].empty?)
        code[0] = "0"
      end

      (0..code.size).each do |i|
        c = !code[i].empty? ? code[i].to_i : 0
        case c
        when 0 # normal
          bg = dfl & 0x1ff
          fg = (dfl >> 9) & 0x1ff
          flags = (dfl >> 18) & 0x1ff
          break
        when 1 # bold
          flags |= 1
          break
        when 22
          flags = (dfl >> 18) & 0x1ff
          break
        when 4 # underline
          flags |= 2
          break
        when 24
          flags = (dfl >> 18) & 0x1ff
          break
        when 5 # blink
          flags |= 4
          break
        when 25
          flags = (dfl >> 18) & 0x1ff
          break
        when 7 # inverse
          flags |= 8
          break
        when 27
          flags = (dfl >> 18) & 0x1ff
          break
        when 8 # invisible
          flags |= 16
          break
        when 28
          flags = (dfl >> 18) & 0x1ff
          break
        when 39 # default fg
          fg = (dfl >> 9) & 0x1ff
          break
        when 49 # default bg
          bg = dfl & 0x1ff
          break
        when 100 # default fg/bg
          fg = (dfl >> 9) & 0x1ff
          bg = dfl & 0x1ff
          break
        else # color
          if (c == 48 && code[i + 1].to_i == 5)
            i += 2
            bg = code[i].to_i
            break
          elsif (c == 48 && code[i + 1].to_i == 2)
            i += 2
            bg = Colors.match(code[i].to_i, code[i + 1].to_i, code[i + 2].to_i)
            if (bg == -1)
              bg = dfl & 0x1ff
            end
            i += 2
            break
          elsif (c == 38 && code[i + 1].to_i == 5)
            i += 2
            fg = code[i].to_i
            break
          elsif (c == 38 && code[i + 1].to_i == 2)
            i += 2
            fg = Colors.match(code[i].to_i, code[i + 1].to_i, code[i + 2].to_i)
            if (fg == -1)
              fg = (dfl >> 9) & 0x1ff
            end
            i += 2 # XXX Why ameba says this is no-op?
            break
          end
          if (c >= 40 && c <= 47)
            bg = c - 40
          elsif (c >= 100 && c <= 107)
            bg = c - 100
            bg += 8
          elsif (c == 49)
            bg = dfl & 0x1ff
          elsif (c >= 30 && c <= 37)
            fg = c - 30
          elsif (c >= 90 && c <= 97)
            fg = c - 90
            fg += 8
          elsif (c == 39)
            fg = (dfl >> 9) & 0x1ff
          elsif (c == 100)
            fg = (dfl >> 9) & 0x1ff
            bg = dfl & 0x1ff
          end
          break
        end
      end

      (flags << 18) | (fg << 9) | bg
    end

    # Converts our own attribute format to an SGR string.
    def code2attr(code)
      flags = (code >> 18) & 0x1ff
      fg = (code >> 9) & 0x1ff
      bg = code & 0x1ff
      outbuf = String::Builder.new

      outbuf << "\e[" # #bytesize == 2

      # bold
      if ((flags & 1) != 0)
        outbuf << "1;"
      end

      # underline
      if ((flags & 2) != 0)
        outbuf << "4;"
      end

      # blink
      if ((flags & 4) != 0)
        outbuf << "5;"
      end

      # inverse
      if ((flags & 8) != 0)
        outbuf << "7;"
      end

      # invisible
      if ((flags & 16) != 0)
        outbuf << "8;"
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
          outbuf << bg << ';'
        else
          outbuf << "48;5;" << bg << ';'
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
          outbuf << fg << ';'
        else
          outbuf << "38;5;" << fg << ';'
        end
      end

      # If bytesize is 2, which is what we started with, it means nothing
      # was written, so we should in fact return an empty string.
      if outbuf.bytesize == 2
        return ""
      end

      # Otherwise, something was written to the string. Since we know the
      # last char is ";", we go back one char and replace it with 'm',
      # then return that string.
      outbuf.back 1
      outbuf << 'm'
      outbuf.to_s
    end
    # end
  end
end
