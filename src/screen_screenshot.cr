module Crysterm
  class Screen
    def screenshot(xi = 0, xl = awidth, yi = 0, yl = aheight, term = false)
      xi = 0 if xi < 0
      yi = 0 if yi < 0

      screen_default_attr = @default_attr

      # E O:
      # XXX this functionality is currently commented out throughout the function.
      # Possibly re-enable, or move to separate function.
      # if (term) {
      #  this.default_attr = term.defAttr;
      # }

      main = String::Builder.new

      yi.upto(yl - 1) do |y|
        # line = term
        #  ? term.lines[y]
        #  : this.lines[y]
        line = @lines[y]?

        break if !line

        outbuf = String::Builder.new
        attr = @default_attr

        xi.upto(xl - 1) do |x|
          break if !line[x]?

          data = line[x].attr
          ch = line[x].char

          if data != attr
            outbuf << "\e[m" if attr != @default_attr
            # if term
            #  if (((_data >> 9) & 0x1ff) == 257); _data |= 0x1ff << 9 end
            #  if ((_data & 0x1ff) == 256); _data |= 0x1ff end
            # end
            outbuf << code2attr(data) if data != @default_attr
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
        end

        if attr != @default_attr
          outbuf << "\e[m"
        end

        if outbuf.bytesize > 0
          main << '\n' if y > yi
          main << outbuf.to_s
        end
      end

      main = main.to_s # .rstrip
      main = main.sub(/(?:\s*\e\[40m\s*\e\[m\s*)*$/, "")
      main += '\n'

      # if term
      #  @default_attr = screen_default_attr
      # end

      main
    end
  end
end
