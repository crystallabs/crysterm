module Crysterm
  class Screen
    # Conversion between SGR sequences and Crysterm's attribute format.
    #
    # The attribute word is packed/unpacked via `Crysterm::Attr` (24-bit RGB
    # fg/bg + flags, in an `Int64`). Colors are kept at full TrueColor precision
    # internally and only reduced (to 256/16/8) when emitted, based on
    # `#colors`.

    # Number of colors the output terminal supports (2, 8, 16, 256, or
    # 16_777_216 for TrueColor). Drives color reduction at output time.
    def colors
      tput.features.number_of_colors
    end

    # Whether the output terminal can render the full 24-bit (TrueColor) space,
    # i.e. colors are emitted as `38;2;r;g;b` rather than reduced to a palette.
    def truecolor?
      colors >= 0x1000000
    end

    # Converts an SGR string to our own attribute format (an `Int64`).
    def attr2code(code, cur : Int64, dfl : Int64) : Int64
      flags = Attr.flags(cur)
      fg = Attr.fg(cur) # packed color field (RGB or COLOR_DEFAULT)
      bg = Attr.bg(cur)

      parts = code[2...-1].split(';')
      if !parts[0]? || parts[0].empty?
        parts[0] = "0"
      end

      # NOTE: an SGR sequence can carry several codes (e.g. `\e[1;31m` =
      # bold + red), so every code must be applied in turn. We use an explicit
      # index because the truecolor/256-color forms consume several codes at
      # once and need to advance `i` past their parameters.
      i = 0
      while i < parts.size
        c = !parts[i].empty? ? parts[i].to_i : 0
        case c
        when 0 # normal
          bg = Attr.bg(dfl)
          fg = Attr.fg(dfl)
          flags = Attr.flags(dfl)
        when 1 # bold
          flags |= Attr::BOLD
        when 22
          flags = Attr.flags(dfl)
        when 4 # underline
          flags |= Attr::UNDERLINE
        when 24
          flags = Attr.flags(dfl)
        when 5 # blink
          flags |= Attr::BLINK
        when 25
          flags = Attr.flags(dfl)
        when 7 # inverse
          flags |= Attr::INVERSE
        when 27
          flags = Attr.flags(dfl)
        when 8 # invisible
          flags |= Attr::INVISIBLE
        when 28
          flags = Attr.flags(dfl)
        when 39 # default fg
          fg = Attr.fg(dfl)
        when 49 # default bg
          bg = Attr.bg(dfl)
        when 38, 48 # extended fg (38) / bg (48): 256-color or truecolor
          mode = parts[i + 1]?.try &.to_i
          if mode == 5 # `<38|48>;5;n` (256-color): store as native RGB
            rgb = Colors.palette_to_rgb(parts[i + 2]?.try(&.to_i) || 0)
            c == 38 ? (fg = Attr.pack_color(rgb)) : (bg = Attr.pack_color(rgb))
            i += 2
          elsif mode == 2 # `<38|48>;2;r;g;b` (truecolor): store RGB directly
            r = parts[i + 2]?.try(&.to_i) || 0
            g = parts[i + 3]?.try(&.to_i) || 0
            b = parts[i + 4]?.try(&.to_i) || 0
            rgb = (r << 16) | (g << 8) | b
            c == 38 ? (fg = Attr.pack_color(rgb)) : (bg = Attr.pack_color(rgb))
            i += 4
          end
        else # 8/16-color fg/bg, including bright variants — store as native RGB
          if c >= 40 && c <= 47
            bg = Attr.pack_color(Colors.palette_to_rgb(c - 40))
          elsif c >= 100 && c <= 107 # bright bg (100 = bright black bg, not "default")
            bg = Attr.pack_color(Colors.palette_to_rgb(c - 100 + 8))
          elsif c >= 30 && c <= 37
            fg = Attr.pack_color(Colors.palette_to_rgb(c - 30))
          elsif c >= 90 && c <= 97 # bright fg
            fg = Attr.pack_color(Colors.palette_to_rgb(c - 90 + 8))
          end
        end
        i += 1
      end

      Attr.pack(flags, fg, bg)
    end

    # Converts our own attribute format to an SGR string.
    def code2attr(code : Int64) : String
      flags = Attr.flags(code)
      fg = Attr.unpack_color(Attr.fg(code)) # -1 (default) or 0xRRGGBB
      bg = Attr.unpack_color(Attr.bg(code))
      n = colors

      String.build do |outbuf|
        outbuf << "\e["

        outbuf << "1;" if (flags & Attr::BOLD) != 0
        outbuf << "4;" if (flags & Attr::UNDERLINE) != 0
        outbuf << "5;" if (flags & Attr::BLINK) != 0
        outbuf << "7;" if (flags & Attr::INVERSE) != 0
        outbuf << "8;" if (flags & Attr::INVISIBLE) != 0

        # Default colors (-1) emit nothing (the terminal's own default applies);
        # concrete colors are encoded at the richest depth the terminal allows.
        if bg != -1
          Colors.sgr_color_to(outbuf, bg, false, n)
          outbuf << ';'
        end
        if fg != -1
          Colors.sgr_color_to(outbuf, fg, true, n)
          outbuf << ';'
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
  end
end
