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
    #
    # Delegates to the pure class method: the conversion depends only on its
    # arguments (no screen/tput state), which also makes it unit-testable
    # without constructing a `Screen`.
    def attr2code(code, cur : Int64, dfl : Int64) : Int64
      self.class.attr2code code, cur, dfl
    end

    # :ditto:
    def self.attr2code(code, cur : Int64, dfl : Int64) : Int64
      flags = Attr.flags(cur)
      fg = Attr.fg(cur) # packed color field (RGB or COLOR_DEFAULT)
      bg = Attr.bg(cur)

      # Parse the SGR parameters in place (the digits between "\e[" and the
      # trailing "m") rather than `code[2...-1].split(';')`, which allocated a
      # substring plus an `Array(String)` of per-parameter strings on every
      # color change — and `attr2code` runs per SGR sequence on every frame for
      # colored content. SGR is ASCII, so we scan the byte view directly. An
      # empty parameter (e.g. `\e[m`, or `\e[;1m`) counts as 0, matching
      # `split`'s semantics; the truecolor/256-color forms read and consume
      # their extra parameters via `term`.
      bytes = code.to_slice
      finish = bytes.size - 1 # index of the trailing 'm'
      pos = 2                 # first parameter byte (after "\e[")

      loop do
        c, term = sgr_param_at(bytes, pos, finish)
        case c
        when 0 # normal
          bg = Attr.bg(dfl)
          fg = Attr.fg(dfl)
          flags = Attr.flags(dfl)
        when 1 # bold
          flags |= Attr::BOLD
        when 4 # underline
          flags |= Attr::UNDERLINE
        when 5 # blink
          flags |= Attr::BLINK
        when 7 # inverse
          flags |= Attr::INVERSE
        when 8 # invisible
          flags |= Attr::INVISIBLE
        when 22, 24, 25, 27, 28 # reset the respective style attribute(s)
          flags = Attr.flags(dfl)
        when 39 # default fg
          fg = Attr.fg(dfl)
        when 49 # default bg
          bg = Attr.bg(dfl)
        when 38, 48 # extended fg (38) / bg (48): 256-color or truecolor
          if term < finish
            mode, mterm = sgr_param_at(bytes, term + 1, finish)
            if mode == 5 && mterm < finish # `<38|48>;5;n` (256-color)
              n, nterm = sgr_param_at(bytes, mterm + 1, finish)
              rgb = Colors.palette_to_rgb(n)
              c == 38 ? (fg = Attr.pack_color(rgb)) : (bg = Attr.pack_color(rgb))
              term = nterm
            elsif mode == 2 && mterm < finish # `<38|48>;2;r;g;b` (truecolor)
              r, rterm = sgr_param_at(bytes, mterm + 1, finish)
              g, gterm = rterm < finish ? sgr_param_at(bytes, rterm + 1, finish) : {0, rterm}
              b, bterm = gterm < finish ? sgr_param_at(bytes, gterm + 1, finish) : {0, gterm}
              rgb = (r << 16) | (g << 8) | b
              c == 38 ? (fg = Attr.pack_color(rgb)) : (bg = Attr.pack_color(rgb))
              term = bterm
            else
              term = mterm
            end
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

        break if term >= finish
        pos = term + 1
      end

      Attr.pack(flags, fg, bg)
    end

    # Parses one ';'-separated decimal SGR parameter from `bytes` starting at
    # `pos`, stopping at the next ';' or at `finish` (the index of the trailing
    # 'm'). Returns `{value, terminator}` where `terminator` is the index of the
    # ';' or `finish`. An empty parameter yields 0. Allocation-free helper for
    # `attr2code`; assumes ASCII digits (guaranteed by `SGR_REGEX`).
    private def self.sgr_param_at(bytes : Bytes, pos : Int32, finish : Int32) : {Int32, Int32}
      value = 0
      while pos < finish
        b = bytes.unsafe_fetch(pos)
        break if b == ';'.ord
        value = value * 10 + (b.to_i - '0'.ord)
        pos += 1
      end
      {value, pos}
    end

    # Converts our own attribute format to an SGR string.
    def code2attr(code : Int64) : String
      String.build { |outbuf| Screen.code2attr_to(outbuf, code, colors) }
    end

    # Allocation-free counterpart of `code2attr`: writes the SGR sequence for
    # `code` straight into `io` instead of building and returning a fresh
    # `String`. `n` is the terminal's color count (`#colors`). Emits nothing
    # when `code` carries no flags and only default colors.
    #
    # Used on the draw hot path (the BCE line-clear in `screen_drawing`), where
    # `code2attr` would otherwise allocate a `String` for every cleared line on
    # every frame — per-frame garbage that the rest of the draw loop already
    # avoids by emitting SGR inline. See `benchmarks/render-hotpath.cr`.
    #
    # `io` must support seeking backwards (an `IO::Memory`, as the draw buffers
    # are); the mechanism mirrors the inline SGR emission in `screen_drawing`.
    def self.code2attr_to(io : IO::Memory, code : Int64, n : Int) : Nil
      flags = Attr.flags(code)
      fg = Attr.unpack_color(Attr.fg(code)) # -1 (default) or 0xRRGGBB
      bg = Attr.unpack_color(Attr.bg(code))

      # Decide up front whether the sequence is non-empty (matching `code2attr`'s
      # "" return for the default attr). This avoids writing "\e[" only to have
      # to truncate it back out of the IO when nothing follows.
      style_flags = flags & (Attr::BOLD | Attr::UNDERLINE | Attr::BLINK | Attr::INVERSE | Attr::INVISIBLE)
      return if style_flags == 0 && fg == -1 && bg == -1

      io << "\e["

      io << "1;" if (flags & Attr::BOLD) != 0
      io << "4;" if (flags & Attr::UNDERLINE) != 0
      io << "5;" if (flags & Attr::BLINK) != 0
      io << "7;" if (flags & Attr::INVERSE) != 0
      io << "8;" if (flags & Attr::INVISIBLE) != 0

      # Default colors (-1) emit nothing (the terminal's own default applies);
      # concrete colors are encoded at the richest depth the terminal allows.
      if bg != -1
        Colors.sgr_color_to(io, bg, false, n)
        io << ';'
      end
      if fg != -1
        Colors.sgr_color_to(io, fg, true, n)
        io << ';'
      end

      # Something was written and the last char is ';'. Back up over it and
      # replace it with the terminating 'm'.
      io.seek -1, IO::Seek::Current
      io << 'm'
    end
  end
end
