module Crysterm
  class Screen
    # Conversion between SGR sequences and Crysterm's attribute format.
    #
    # The attribute word is packed/unpacked via `Crysterm::Attr` (24-bit RGB
    # fg/bg + flags, in an `Int64`). Colors are kept at full TrueColor precision
    # internally and only reduced (to 256/16/8) when emitted, based on
    # `#colors`.

    # Number of colors the output terminal supports (1 for monochrome, 8, 16,
    # 256, or 16_777_216 for TrueColor). Drives color reduction at output time.
    # The terminal-detected count is overridden by the `colors.depth` config
    # option and the `NO_COLOR` / `FORCE_COLOR` / `CLICOLOR[_FORCE]` env vars —
    # see `.resolve_color_depth`.
    #
    # Computed fresh on each call (it is read once per frame, not per cell), so
    # it always reflects the *current* `colors.depth` — including overrides
    # Superconf applies from a config file / env / CLI flag, at any point — and
    # the live environment, rather than freezing a value at first paint.
    def colors : Int32
      self.class.resolve_color_depth(tput.features.number_of_colors)
    end

    # Resolves the effective output color count from the `colors.depth` config
    # option and the `screen.color_force` policy (resolved once at startup from
    # the `NO_COLOR` / `FORCE_COLOR` / `CLICOLOR[_FORCE]` conventions — see
    # `Crysterm.color_force_from_env`), falling back to the terminal-*detected*
    # count. Result `1` means monochrome (no color emitted; styles still apply),
    # then `8` / `16` / `256` / `0x1000000` (TrueColor).
    def self.resolve_color_depth(detected : Int32) : Int32
      # An explicit config depth wins outright.
      if forced = Config.colors_depth.to_count
        return forced
      end
      case Config.screen_color_force
      in ColorForce::None      then detected
      in ColorForce::Mono      then 1
      in ColorForce::Min16     then {detected, 16}.max
      in ColorForce::Min256    then {detected, 256}.max
      in ColorForce::Truecolor then 0x1000000
      end
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

    # :ditto: (allocation-free `StringIndex` form, see the class method).
    def attr2code(content : StringIndex, esc : Int32, finish : Int32, cur : Int64, dfl : Int64) : Int64
      self.class.attr2code content, esc, finish, cur, dfl
    end

    # :ditto:
    def self.attr2code(code, cur : Int64, dfl : Int64) : Int64
      # `code` is a whole SGR string ("\e[...m"); its bytes are the parameter
      # source. `to_slice` is allocation-free (it views the string's buffer).
      bytes = code.to_slice
      attr2code_impl bytes, 2, bytes.size - 1, cur, dfl
    end

    # Converts a *bare* SGR parameter list — just the `;`-separated numbers, with
    # no `\e[` framing and no trailing `m` (e.g. the `@csi_buf` a
    # `TerminalEmulator` accumulates) — into our `Int64` attribute. Equivalent to
    # `attr2code("\e[" + params + "m", cur, dfl)` but without building that
    # bridging `String` on every SGR sequence the child terminal emits.
    def self.attr2code_params(params : String, cur : Int64, dfl : Int64) : Int64
      bytes = params.to_slice
      attr2code_impl bytes, 0, bytes.size, cur, dfl
    end

    # :ditto: but reading the parameter bytes straight out of a `Bytes` view
    # (e.g. an `IO::Memory#to_slice` over a reused CSI accumulation buffer), so
    # the caller never has to materialize a `String` per SGR sequence.
    def self.attr2code_params(params : Bytes, cur : Int64, dfl : Int64) : Int64
      attr2code_impl params, 0, params.size, cur, dfl
    end

    # Parses an SGR sequence straight out of a `StringIndex` between the
    # codepoint index of its `\e` (*esc*) and that of its trailing `m`
    # (*finish*), with NO intermediate substring. This is the render hot path's
    # entry point: `widget_rendering` already locates the sequence's bounds while
    # scanning content codepoint-by-codepoint, so feeding those bounds here
    # avoids the per-escape `Regex::MatchData` + matched-substring `String` that
    # `SGR_REGEX.match` + `code[0]` used to allocate on every color change.
    # SGR is pure ASCII, so codepoints and bytes coincide within the sequence.
    def self.attr2code(content : StringIndex, esc : Int32, finish : Int32, cur : Int64, dfl : Int64) : Int64
      attr2code_impl content, esc + 2, finish, cur, dfl
    end

    # Shared SGR state machine. `src` is any parameter source understood by an
    # `sgr_param_at` overload (a `Bytes` byte view, or a `StringIndex`); Crystal
    # instantiates this once per source type. `pos0` is the index of the first
    # parameter (just past "\e["), `finish` the index of the trailing 'm'. An
    # empty parameter (e.g. `\e[m`, or `\e[;1m`) counts as 0, matching the old
    # `split(';')` semantics; the truecolor/256-color forms read and consume
    # their extra parameters via `term`.
    # ameba:disable Metrics/CyclomaticComplexity
    private def self.attr2code_impl(src, pos0 : Int32, finish : Int32, cur : Int64, dfl : Int64) : Int64
      flags = Attr.flags(cur)
      fg = Attr.fg(cur) # packed color field (RGB or COLOR_DEFAULT)
      bg = Attr.bg(cur)

      pos = pos0

      loop do
        c, term = sgr_param_at(src, pos, finish)
        case c
        when 0 # normal
          bg = Attr.bg(dfl)
          fg = Attr.fg(dfl)
          flags = Attr.flags(dfl)
        when 1 # bold
          flags |= Attr::BOLD
        when 3 # italic
          flags |= Attr::ITALIC
        when 4 # underline
          flags |= Attr::UNDERLINE
        when 5 # blink
          flags |= Attr::BLINK
        when 7 # reverse
          flags |= Attr::REVERSE
        when 8 # invisible
          flags |= Attr::INVISIBLE
        when 9 # strikethrough
          flags |= Attr::STRIKE
          # Each of these turns off ONLY its respective style attribute (leaving
          # the others intact), per ECMA-48 — not a blanket flags reset. Clearing
          # all flags here would make e.g. `{bold}{underline}x{/underline}y` drop
          # the still-open bold on `y`. (For the common single-flag case the result
          # is identical, since only the one set bit is cleared.)
        when 22 then flags &= ~Attr::BOLD.to_i64      # normal intensity (bold off)
        when 23 then flags &= ~Attr::ITALIC.to_i64    # italic off
        when 24 then flags &= ~Attr::UNDERLINE.to_i64 # underline off
        when 25 then flags &= ~Attr::BLINK.to_i64     # blink off
        when 27 then flags &= ~Attr::REVERSE.to_i64   # reverse off
        when 28 then flags &= ~Attr::INVISIBLE.to_i64 # reveal (invisible off)
        when 29 then flags &= ~Attr::STRIKE.to_i64    # strikethrough off
        when 39                                       # default fg
          fg = Attr.fg(dfl)
        when 49 # default bg
          bg = Attr.bg(dfl)
        when 38, 48 # extended fg (38) / bg (48): 256-color or truecolor
          if term < finish
            mode, mterm = sgr_param_at(src, term + 1, finish)
            if mode == 5 && mterm < finish # `<38|48>;5;n` (256-color)
              n, nterm = sgr_param_at(src, mterm + 1, finish)
              rgb = Colors.palette_to_rgb(n)
              c == 38 ? (fg = Attr.pack_color(rgb)) : (bg = Attr.pack_color(rgb))
              term = nterm
            elsif mode == 2 && mterm < finish # `<38|48>;2;r;g;b` (truecolor)
              r, rterm = sgr_param_at(src, mterm + 1, finish)
              g, gterm = rterm < finish ? sgr_param_at(src, rterm + 1, finish) : {0, rterm}
              b, bterm = gterm < finish ? sgr_param_at(src, gterm + 1, finish) : {0, gterm}
              rgb = (r << 16) | (g << 8) | b
              c == 38 ? (fg = Attr.pack_color(rgb)) : (bg = Attr.pack_color(rgb))
              term = bterm
            else
              term = mterm
            end
          end
          # 8/16-color fg/bg, including bright variants — stored as native RGB.
        when 40..47   then bg = Attr.pack_color(Colors.palette_to_rgb(c - 40))
        when 100..107 then bg = Attr.pack_color(Colors.palette_to_rgb(c - 100 + 8)) # bright bg (100 = bright black bg, not "default")
        when 30..37   then fg = Attr.pack_color(Colors.palette_to_rgb(c - 30))
        when 90..97   then fg = Attr.pack_color(Colors.palette_to_rgb(c - 90 + 8)) # bright fg
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
    # Largest value we keep accumulating below; one more digit past this would
    # overflow `Int32`. A param this large is not a real SGR code, so we stop
    # accumulating (freezing it at an unrecognized magnitude) rather than raise
    # `OverflowError` on adversarial input like `\e[9999999999m`.
    SGR_PARAM_MAX = (Int32::MAX - 9) // 10

    private def self.sgr_param_at(bytes : Bytes, pos : Int32, finish : Int32) : {Int32, Int32}
      value = 0
      while pos < finish
        b = bytes.unsafe_fetch(pos)
        break if b == ';'.ord
        value = value * 10 + (b.to_i - '0'.ord) if value <= SGR_PARAM_MAX
        pos += 1
      end
      {value, pos}
    end

    # `StringIndex` counterpart of the `Bytes` overload above, for the
    # allocation-free render path: reads the parameter's ASCII digits by
    # codepoint index instead of byte index. Same contract (empty parameter -> 0,
    # stop at ';' or `finish`).
    private def self.sgr_param_at(content : StringIndex, pos : Int32, finish : Int32) : {Int32, Int32}
      value = 0
      while pos < finish
        ch = content[pos]
        break if ch.nil? || ch == ';'
        value = value * 10 + (ch.ord - '0'.ord) if value <= SGR_PARAM_MAX
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
      style_flags = flags & (Attr::BOLD | Attr::ITALIC | Attr::UNDERLINE | Attr::BLINK | Attr::REVERSE | Attr::INVISIBLE | Attr::STRIKE)
      return if style_flags == 0 && fg == -1 && bg == -1

      io << "\e["
      sgr_params_to(io, code, n)
      # Something was written (the guard above guarantees it) and the last char
      # is ';'. Back up over it and replace it with the terminating 'm'.
      io.seek -1, IO::Seek::Current
      io << 'm'
    end

    # Writes the SGR style-flag and color parameters of `code` (the part between
    # the leading `"\e["` and the terminating `"m"`) into `io`, each parameter
    # followed by `';'`. Returns whether anything was written (i.e. whether
    # `code` carries any flags or non-default color). `n` is the terminal's
    # color count (`#colors`).
    #
    # Shared by `code2attr_to` and the inline SGR emission on the draw hot path
    # (`screen_drawing`); those two differ only in their framing (when to emit
    # `"\e["`, whether to early-return, how to terminate), so only this identical
    # middle portion is factored out here.
    def self.sgr_params_to(io : IO::Memory, code : Int64, n : Int) : Bool
      start = io.size
      flags = Attr.flags(code)

      io << "1;" if (flags & Attr::BOLD) != 0
      io << "3;" if (flags & Attr::ITALIC) != 0
      io << "4;" if (flags & Attr::UNDERLINE) != 0
      io << "5;" if (flags & Attr::BLINK) != 0
      io << "7;" if (flags & Attr::REVERSE) != 0
      io << "8;" if (flags & Attr::INVISIBLE) != 0
      io << "9;" if (flags & Attr::STRIKE) != 0

      # Default colors (-1) emit nothing (the terminal's own default applies);
      # concrete colors are encoded at the richest depth the terminal allows.
      bg = Attr.unpack_color(Attr.bg(code))
      fg = Attr.unpack_color(Attr.fg(code))
      if bg != -1
        Colors.sgr_color_to(io, bg, false, n)
        io << ';'
      end
      if fg != -1
        Colors.sgr_color_to(io, fg, true, n)
        io << ';'
      end

      io.size != start
    end
  end
end
