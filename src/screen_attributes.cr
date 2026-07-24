module Crysterm
  class Screen
    # Conversion between SGR sequences and Crysterm's attribute format.
    #
    # The attribute word is packed/unpacked via `Crysterm::Attr` (24-bit RGB
    # fg/bg + flags, in an `Int64`). Colors are kept at full TrueColor precision
    # internally and only reduced (to 256/16/8) when emitted, based on
    # `#color_count`.

    # Number of colors the output terminal supports (1 for monochrome, 8, 16,
    # 256, or 16_777_216 for TrueColor). Drives color reduction at output time.
    # The terminal-detected count is overridden by the `colors.depth` config
    # option and the `NO_COLOR` / `FORCE_COLOR` / `CLICOLOR[_FORCE]` env vars.
    #
    # Computed fresh on each call — cheap enough at once per frame, and it must
    # not freeze a value at first paint, since an override can land at any time.
    def color_count : Int32
      self.class.resolve_color_depth(tput.features.number_of_colors)
    end

    # :ditto: (alias; call sites are wide, so kept for compatibility).
    def colors : Int32
      color_count
    end

    # Resolves the effective output color count from the `colors.depth` config
    # option and the `screen.color_force` policy (resolved once at startup from
    # the `NO_COLOR` / `FORCE_COLOR` / `CLICOLOR[_FORCE]` conventions), falling
    # back to the terminal-detected count. `1` means monochrome (no color
    # emitted; styles still apply).
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
      color_count >= 0x1000000
    end

    # Converts an SGR string to our own attribute format (an `Int64`).
    #
    # Delegates to the pure class method: the conversion depends only on its
    # arguments, no screen/tput state.
    def sgr_to_attr(code, cur : Int64, dfl : Int64) : Int64
      self.class.sgr_to_attr code, cur, dfl
    end

    # :ditto: (allocation-free `StringIndex` form, see the class method).
    def sgr_to_attr(content : StringIndex, esc : Int32, finish : Int32, cur : Int64, dfl : Int64) : Int64
      self.class.sgr_to_attr content, esc, finish, cur, dfl
    end

    # :ditto:
    def self.sgr_to_attr(code, cur : Int64, dfl : Int64) : Int64
      # `code` is a whole SGR string ("\e[...m"); its bytes are the parameter
      # source. `to_slice` is allocation-free (it views the string's buffer).
      bytes = code.to_slice
      sgr_to_attr_impl bytes, 2, bytes.size - 1, cur, dfl
    end

    # Converts a bare SGR parameter list — `;`-separated numbers, no `\e[`
    # framing, no trailing `m` — into our `Int64` attribute. Equivalent to
    # `sgr_to_attr("\e[" + params + "m", cur, dfl)` without building that bridging
    # `String` per SGR sequence.
    def self.sgr_params_to_attr(params : String, cur : Int64, dfl : Int64) : Int64
      bytes = params.to_slice
      sgr_to_attr_impl bytes, 0, bytes.size, cur, dfl
    end

    # :ditto: reading the parameter bytes straight out of a `Bytes` view,
    # avoiding a `String` per SGR sequence.
    def self.sgr_params_to_attr(params : Bytes, cur : Int64, dfl : Int64) : Int64
      sgr_to_attr_impl params, 0, params.size, cur, dfl
    end

    # Parses an SGR sequence straight out of a `StringIndex` between the
    # codepoint index of its `\e` (*esc*) and its trailing `m` (*finish*), with
    # no intermediate substring. Render hot path entry point: the caller already
    # locates the sequence's bounds while scanning codepoint-by-codepoint, so
    # feeding them here avoids a regex match + substring per color change. SGR is
    # pure ASCII, so codepoints and bytes coincide within the sequence.
    def self.sgr_to_attr(content : StringIndex, esc : Int32, finish : Int32, cur : Int64, dfl : Int64) : Int64
      sgr_to_attr_impl content, esc + 2, finish, cur, dfl
    end

    # Shared SGR state machine. `src` is any parameter source understood by an
    # `sgr_param_at` overload (`Bytes` or `StringIndex`); Crystal instantiates
    # this once per source type. `pos0` is the index of the first parameter
    # (just past "\e["), `finish` the index of the trailing 'm'. An empty
    # parameter (e.g. `\e[m`, `\e[;1m`) counts as 0, matching `split(';')`
    # semantics; truecolor/256-color forms read and consume extra params via `term`.
    # ameba:disable Metrics/CyclomaticComplexity
    private def self.sgr_to_attr_impl(src, pos0 : Int32, finish : Int32, cur : Int64, dfl : Int64) : Int64
      flags = Attr.flags(cur)
      fg = Attr.fg(cur) # packed color field (RGB or COLOR_DEFAULT)
      bg = Attr.bg(cur)

      pos = pos0

      loop do
        c, term, colon = sgr_param_at(src, pos, finish)
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
          # Each of these turns off only its own flag (per ECMA-48), not a
          # blanket reset — clearing all flags would drop still-open bold on
          # e.g. `{bold}{underline}x{/underline}y`.
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
        when 38, 48, 58 # extended fg (38) / bg (48) / underline color (58): 256-color or truecolor.
          # Sub-parameters may be `;`- or `:`-separated (ISO 8613-6 / ITU T.416):
          # `38;5;n` / `38:5:n`, `38;2;r;g;b` / `38:2:r:g:b`, and the full colon
          # form `38:2:<cs>:r:g:b` with a (usually empty) colorspace-id field.
          # 58 shares the exact same payload shape (`58;2;r;g;b` / `58:5:n` /
          # `58:2:<cs>:r:g:b`) but crysterm has no underline-color attribute to
          # set — its payload is parsed identically to 38/48 solely so `term`
          # (and `colon`, below) land past it instead of leaking sub-parameters
          # into the top-level SGR loop as standalone codes.
          if term < finish
            mode, mterm, mcolon = sgr_param_at(src, term + 1, finish)
            if mode == 5 && mterm < finish # `<38|48|58>[;:]5[;:]n` (256-color)
              n, nterm, ncolon = sgr_param_at(src, mterm + 1, finish)
              if c == 38
                fg = Attr.pack_color(Colors.palette_to_rgb(n))
              elsif c == 48
                bg = Attr.pack_color(Colors.palette_to_rgb(n))
              end
              term = nterm
              colon = ncolon
            elsif mode == 2 && mterm < finish # `<38|48|58>[;:]2[;:]r[;:]g[;:]b` (truecolor)
              rstart = mterm
              # The colon form may carry a leading colorspace-id field
              # (`38:2::r:g:b` / `38:2:<cs>:r:g:b`). Count the colon-separated
              # fields after `2`; 4 of them means the first is the colorspace id
              # and must be skipped so r/g/b line up.
              if mcolon
                fields = 0
                p = mterm
                loop do
                  _, p, pcolon = sgr_param_at(src, p + 1, finish)
                  fields += 1
                  break unless pcolon
                end
                if fields >= 4
                  _, rstart, _ = sgr_param_at(src, mterm + 1, finish)
                end
              end
              r, rterm, _ = sgr_param_at(src, rstart + 1, finish)
              g, gterm, _ = rterm < finish ? sgr_param_at(src, rterm + 1, finish) : {0, rterm, false}
              b, bterm, bcolon = gterm < finish ? sgr_param_at(src, gterm + 1, finish) : {0, gterm, false}
              if c == 38
                fg = Attr.pack_color(Colors.rgb(r, g, b))
              elsif c == 48
                bg = Attr.pack_color(Colors.rgb(r, g, b))
              end
              term = bterm
              colon = bcolon
            else
              term = mterm
              colon = mcolon
            end
          end
        when 59 # default underline color — no-op (crysterm has no underline-color attr)
          # 8/16-color fg/bg, including bright variants — stored as native RGB.
        when 40..47   then bg = Attr.pack_color(Colors.palette_to_rgb(c - 40))
        when 100..107 then bg = Attr.pack_color(Colors.palette_to_rgb(c - 100 + 8)) # bright bg (100 = bright black bg, not "default")
        when 30..37   then fg = Attr.pack_color(Colors.palette_to_rgb(c - 30))
        when 90..97   then fg = Attr.pack_color(Colors.palette_to_rgb(c - 90 + 8)) # bright fg
        end

        # A `:`-terminated parameter we don't consume above carries ISO 8613-6
        # sub-parameters (e.g. `4:3`, curly underline). The base code was already
        # applied by the `case`; skip its sub-params up to the next `;` so the
        # whole SGR isn't dropped (`4:3` degrades to a plain underline). The
        # 38/48/58 branch above already reassigns `colon` (and `term`) to the
        # last sub-parameter it actually consumed — including T.416 trailing
        # fields (unused/tolerance/tolerance-colorspace) beyond r/g/b that it
        # doesn't itself understand — so this same skip drains those leftovers
        # too instead of needing a separate exemption for those codes.
        if colon
          loop do
            _, term, colon = sgr_param_at(src, term + 1, finish)
            break unless colon
          end
        end

        break if term >= finish
        pos = term + 1
      end

      Attr.pack(flags, fg, bg)
    end

    # Largest value to keep accumulating; one more digit would overflow `Int32`.
    # A param this large isn't a real SGR code, so accumulation just stops
    # instead of raising `OverflowError` on adversarial input like
    # `\e[9999999999m`.
    SGR_PARAM_MAX = (Int32::MAX - 9) // 10

    # Parses one decimal SGR parameter from `bytes` starting at `pos`, stopping
    # at the next ';' or ':' separator or at `finish` (index of trailing 'm').
    # Returns `{value, terminator, colon?}`, where `colon?` marks an ISO 8613-6 /
    # ITU T.416 sub-parameter separator. An empty parameter yields 0.
    # Allocation-free. Non-digit bytes other than the two separators are ignored:
    # the params entry points feed the raw CSI buffer with no pre-validation, so
    # this must not assume clean input.
    private def self.sgr_param_at(bytes : Bytes, pos : Int32, finish : Int32) : {Int32, Int32, Bool}
      value = 0
      colon = false
      while pos < finish
        b = bytes.unsafe_fetch(pos)
        break if b == ';'.ord
        if b == ':'.ord
          colon = true
          break
        end
        value = value * 10 + (b.to_i - '0'.ord) if value <= SGR_PARAM_MAX
        pos += 1
      end
      {value, pos, colon}
    end

    # `StringIndex` counterpart of the `Bytes` overload above: reads the
    # parameter's ASCII digits by codepoint index instead of byte index. Same
    # contract (empty parameter -> 0, stop at ';'/':' or `finish`, report ':').
    private def self.sgr_param_at(content : StringIndex, pos : Int32, finish : Int32) : {Int32, Int32, Bool}
      value = 0
      colon = false
      while pos < finish
        ch = content[pos]
        break if ch.nil? || ch == ';'
        if ch == ':'
          colon = true
          break
        end
        value = value * 10 + (ch.ord - '0'.ord) if value <= SGR_PARAM_MAX
        pos += 1
      end
      {value, pos, colon}
    end

    # Converts our own attribute format to an SGR string.
    def attr_to_sgr(code : Int64) : String
      String.build { |outbuf| Screen.write_sgr(outbuf, code, color_count) }
    end

    # Bounded cache of the full SGR set-sequence bytes for an `(attr, ncolors)`
    # pair — the `write_sgr` output for that attr (`"\e[...m"`, or empty). The
    # draw loop re-encodes the same handful of concrete-color attrs across every
    # dirty row of every frame; in truecolor each encode does per-channel `itoa`
    # + several `io <<` writes. Caching turns a per-transition synthesis into a
    # hash probe + `memcpy`. Keyed on the packed attr and the frame-constant
    # color count (both fully determine the bytes), so it is a pure function.
    @@sgr_bytes_cache = Cache::Bounded({Int64, Int32}, Bytes).new(Cache::COLOR_CAPACITY, "sgr_bytes", register: true)

    # Returns the cached SGR set-sequence bytes for `code` at color count `n`
    # (identical to what `write_sgr` would write), synthesizing and storing on a
    # miss. Intended for concrete-color transitions on the draw hot path (see
    # `#has_concrete_color?`); flag-only/default attrs are cheap enough to synth
    # directly and skip the lookup.
    def self.sgr_bytes(code : Int64, n : Int) : Bytes
      @@sgr_bytes_cache.fetch({code, n.to_i32}) do
        io = IO::Memory.new 24
        write_sgr(io, code, n)
        io.to_slice.dup
      end
    end

    # Whether `code` carries at least one concrete (non-default) color — the gate
    # for using the `sgr_bytes` cache. A flag-only/all-default attr encodes
    # trivially, so caching it would only add a hash probe.
    @[AlwaysInline]
    def self.has_concrete_color?(code : Int64) : Bool
      Attr.fg(code) != Attr::COLOR_DEFAULT || Attr.bg(code) != Attr::COLOR_DEFAULT
    end

    # Whether BOTH color channels of `code` are concrete (neither is the terminal
    # default). Such an attr's SGR spec re-sends both colors, overwriting whatever
    # colors were previously in effect — the precondition (together with a flag
    # superset) for safely dropping the standalone `\e[m` reset on a
    # colored->colored transition (see the draw loop). A default channel would
    # emit no SGR param, so the previous channel's color would leak through.
    @[AlwaysInline]
    def self.has_both_concrete?(code : Int64) : Bool
      Attr.fg(code) != Attr::COLOR_DEFAULT && Attr.bg(code) != Attr::COLOR_DEFAULT
    end

    # Allocation-free counterpart of `attr_to_sgr`: writes the SGR sequence for
    # `code` straight into `io` instead of returning a fresh `String`. `n` is
    # the terminal's color count (`#color_count`). Emits nothing when `code` carries
    # no flags and only default colors.
    #
    # `io` must support seeking backwards (an `IO::Memory`).
    def self.write_sgr(io : IO::Memory, code : Int64, n : Int) : Nil
      flags = Attr.flags(code)
      fg = Attr.unpack_color(Attr.fg(code)) # -1 (default) or 0xRRGGBB
      bg = Attr.unpack_color(Attr.bg(code))

      # Decide up front whether the sequence is non-empty (matching `attr_to_sgr`'s
      # "" return for the default attr), rather than writing "\e[" and having to
      # truncate it back out of the IO when nothing follows.
      style_flags = flags & (Attr::BOLD | Attr::ITALIC | Attr::UNDERLINE | Attr::BLINK | Attr::REVERSE | Attr::INVISIBLE | Attr::STRIKE)
      return if style_flags == 0 && fg == -1 && bg == -1

      io << "\e["
      sgr_params_to(io, code, n)
      # Last char is ';' (guaranteed by the guard above); back up and replace
      # with the terminating 'm'.
      io.seek -1, IO::Seek::Current
      io << 'm'
    end

    # Writes the SGR style-flag and color parameters of `code` (between the
    # leading `"\e["` and terminating `"m"`) into `io`, each followed by `';'`.
    # Returns whether anything was written. `n` is the terminal's color count
    # (`#color_count`). Only the middle portion: framing is the caller's, since the
    # draw hot path and `write_sgr` frame it differently.
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

      # Default colors (-1) emit nothing; concrete colors are encoded at the
      # richest depth the terminal allows.
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
