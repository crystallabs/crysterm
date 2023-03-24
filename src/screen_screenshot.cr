module Crysterm
  class Screen
    def screenshot(xi, xl, yi, yl, term = false)
      if !xi
        xi = 0
      end
      if !xl
        xl = awidth
      end
      if !yi
        yi = 0
      end
      if !yl
        yl = aheight
      end

      if xi < 0
        xi = 0
      end
      if yi < 0
        yi = 0
      end

      screen_default_attr = @default_attr

      # E O:
      # XXX this functionality is currently commented out throughout the function.
      # Possibly re-enable, or move to separate function.
      # if (term) {
      #  this.default_attr = term.defAttr;
      # }

      main = String::Builder.new

      y = yi
      while y < yl
        # line = term
        #  ? term.lines[y]
        #  : this.lines[y]
        line = @lines[y]?

        break if !line

        outbuf = String::Builder.new
        attr = @default_attr

        x = xi
        while x < xl
          break if !line[x]?

          data = line[x].attr
          ch = line[x].char

          if data != attr
            if attr != @default_attr
              outbuf << "\e[m"
            end
            if data != @default_attr
              _data = data
              # if term
              #  if (((_data >> 9) & 0x1ff) == 257); _data |= 0x1ff << 9 end
              #  if ((_data & 0x1ff) == 256); _data |= 0x1ff end
              # end
              outbuf << code2attr(_data)
            end
          end

          # E O:
          # if @full_unicode
          #  if (unicode.charWidth(line[x][1]) === 2) {
          #    if (x === xl - 1) {
          #      ch = ' ';
          #    } else {
          #      x++;
          #    }
          #  }
          # }

          outbuf << ch
          attr = data
          x += 1
        end

        if attr != @default_attr
          outbuf << "\e[m"
        end

        if outbuf.bytesize > 0
          main << '\n' if y > 0
          main << outbuf.to_s
        end

        y += 1
      end

      # XXX Fix the creation of string here
      main = main.to_s
      main = main.sub(/(?:\s*\e\[40m\s*\e\[m\s*)*$/, "")
      main += '\n'

      # if term
      #  @default_attr = screen_default_attr
      # end

      return main
    end
  end
end
