module Crysterm
  class TerminalEmulator
    # ───────────────────────── input ─────────────────────────

    # Feeds raw bytes from the child. Re-assembles UTF-8 across calls so a
    # multibyte character split over two reads is not corrupted.
    def feed(bytes : Bytes) : Nil
      unless @leftover.empty?
        joined = Bytes.new(@leftover.size + bytes.size)
        @leftover.copy_to joined
        bytes.copy_to(joined + @leftover.size)
        bytes = joined
        @leftover = Bytes.empty
      end

      complete, @leftover = split_incomplete_utf8 bytes

      # Fast path: terminal output is overwhelmingly ASCII, so feed those bytes
      # straight as chars without materializing a `String` (control/escape bytes
      # are all ASCII, so the parser is unaffected). A multibyte glyph is decoded
      # in place and the ASCII loop resumes.
      ptr = complete.to_unsafe
      n = complete.size
      i = 0
      while i < n
        b = ptr[i]
        if b < 0x80
          handle_char b.unsafe_chr
          i += 1
        else
          # `split_incomplete_utf8` guarantees whole sequences at the chunk
          # boundary, but a malformed lead *within* the chunk still emits U+FFFD
          # and advances one byte, matching `String`'s replacement behaviour.
          if b < 0xC0
            handle_char '�' # stray continuation byte, no lead
            i += 1
          else
            if b < 0xE0
              cp = (b & 0x1F).to_u32
              len = 2
            elsif b < 0xF0
              cp = (b & 0x0F).to_u32
              len = 3
            else
              cp = (b & 0x07).to_u32
              len = 4
            end
            ok = true
            j = 1
            while j < len
              if i + j >= n
                ok = false # truncated sequence (a following ASCII byte made the chunk "complete")
                break
              end
              cb = ptr[i + j]
              unless 0x80 <= cb <= 0xBF
                ok = false # not a continuation byte
                break
              end
              cp = (cp << 6) | (cb & 0x3F)
              j += 1
            end
            # Continuation bytes alone don't make the glyph valid: a lead >= 0xF8
            # isn't a UTF-8 lead, and the codepoint may be out of range
            # (> U+10FFFF), a UTF-16 surrogate, or an overlong encoding. A real VT
            # substitutes U+FFFD for all of these rather than emitting an invalid
            # Char, which would re-serialize as invalid UTF-8 to the host terminal.
            ok &&= b < 0xF8 &&
                   cp <= 0x10FFFF &&
                   !(0xD800_u32 <= cp <= 0xDFFF_u32) &&
                   cp >= {0x80_u32, 0x800_u32, 0x10000_u32}[len - 2]
            if ok
              handle_char cp.unsafe_chr
              i += len
            else
              handle_char '�'
              i += 1
            end
          end
        end
      end

      @on_refresh.try &.call
    end

    def feed(data : String) : Nil
      feed data.to_slice
    end

    # Splits off any trailing bytes that form an *incomplete* UTF-8 sequence so
    # they can be prepended to the next chunk. Returns {complete, leftover}.
    #
    # The leftover must be `.dup`ed, not returned as a `Slice` view: it is stashed
    # across `#feed` calls, and callers reuse one read buffer, so the next read
    # would overwrite the bytes a view pointed at. `feed` never retains
    # caller-owned memory.
    private def split_incomplete_utf8(bytes : Bytes) : {Bytes, Bytes}
      n = bytes.size
      k = 1
      while k <= 3 && k <= n
        b = bytes[n - k]
        if b >= 0x80 && b < 0xC0
          k += 1 # continuation byte: keep walking back toward the lead byte
          next
        elsif b >= 0xC0
          need = b >= 0xF0 ? 4 : (b >= 0xE0 ? 3 : 2)
          return {bytes[0, n - k], bytes[n - k, k].dup} if k < need
          return {bytes, Bytes.empty}
        else
          return {bytes, Bytes.empty} # ASCII byte: everything up to here is whole
        end
      end
      {bytes, Bytes.empty}
    end

    # True when the parser is inside a non-OSC escape/CSI/charset/hash sequence.
    private def in_escape_sequence? : Bool
      @state == :esc || @state == :csi || @state == :charset || @state == :hash
    end

    private def handle_char(c : Char) : Nil
      # The VT500 "anywhere" transitions. `:osc` is excluded throughout: a string
      # state runs its own ESC/terminator handling and treats controls as payload.
      #
      # ESC mid-sequence aborts the one in progress and begins a *new* escape.
      if c.ord == 0x1b && in_escape_sequence?
        @state = :esc
        return
      end
      # CAN (0x18) / SUB (0x1a) abort the sequence and produce no output.
      if (c.ord == 0x18 || c.ord == 0x1a) && @state != :ground && @state != :osc
        @state = :ground
        return
      end
      # Every other C0 control (0x00-0x1f) executes *immediately* and the
      # in-flight sequence then resumes — a control embedded in a CSI (vttest's
      # `CSI 2 <BS> C`, `CSI <CR> 2 C`, `CSI 1 <VT> A`) is not its final byte.
      if c.ord < 0x20 && in_escape_sequence?
        handle_ground c
        return
      end
      # DEL (0x7f) mid-sequence is ignored: it is neither an intermediate
      # (0x20-0x2f), a parameter (0x30-0x3f), nor a final byte, and must not
      # reach a dispatcher as a spurious final.
      if c.ord == 0x7f && in_escape_sequence?
        return
      end
      case @state
      when :ground  then handle_ground c
      when :esc     then handle_esc c
      when :csi     then handle_csi c
      when :osc     then handle_osc c
      when :charset then handle_charset c
      when :hash    then handle_hash c
      end
    end

    # Final byte of an `ESC #` sequence. Only DECALN (`ESC # 8`, the screen-
    # alignment test) is acted on; the line-size selectors (`ESC # 3`/`4`/`5`/`6`,
    # double-height/width/single-width) are swallowed with no effect, double-sized
    # lines being out of scope.
    private def handle_hash(c : Char) : Nil
      decaln if c == '8'
      @state = :ground
    end

    # Designates the pending G-set (`@charset_index`) as special-graphics when
    # the byte is '0', else as a normal (ASCII-ish) set. Only G0/G1 affect
    # rendering; G2/G3 are tracked-but-unused (rarely invoked as GL).
    private def handle_charset(c : Char) : Nil
      special = c == '0'
      case @charset_index
      when 0 then @g0_special = special
      when 1 then @g1_special = special
      end
      @state = :ground
    end

    private def handle_ground(c : Char) : Nil
      case c.ord
      when 0x1b             then @state = :esc
      when 0x07             then @on_bell.try &.call
      when 0x08             then backspace
      when 0x09             then tab
      when 0x0a, 0x0b, 0x0c then line_feed
      when 0x0d             then @x = 0; @wrap_pending = false
      when 0x0e             then @gl = 1 # SO: invoke G1 into GL
      when 0x0f             then @gl = 0 # SI: invoke G0 into GL
      else
        # 0x7f (DEL) is a fill/padding control, not a glyph: VT100/xterm discard
        # it rather than writing a cell. (0x80+ are printable multibyte glyphs.)
        print_char c if c.ord >= 0x20 && c.ord != 0x7f
      end
    end

    private def handle_esc(c : Char) : Nil
      case c
      when '['
        @state = :csi
        @csi_buf.clear
        @csi_private = false
        @csi_prefix = nil
        @csi_intermediate = false
      when ']'
        @state = :osc
        @osc_buf.clear
        @osc_esc = false
        @osc_string = false
      when '(', ')', '*', '+'
        @charset_index = case c
                         when '(' then 0
                         when ')' then 1
                         when '*' then 2
                         else          3
                         end
        @state = :charset
      when '#'
        @state = :hash
      when ' ', '%'
        # 3-byte intermediate escapes whose final byte must be swallowed, not
        # printed: `ESC SP F/G` (S7C1T/S8C1T) and `ESC % @/G` (charset; always
        # UTF-8 here). Index -1 designates nothing, so the next byte is consumed
        # with no side effect.
        @charset_index = -1
        @state = :charset
      when 'P', 'X', '^', '_'
        # DCS/SOS/PM/APC string — swallow like an OSC (until ST/BEL), but flag it
        # so the payload is discarded rather than parsed as an OSC title.
        @state = :osc
        @osc_buf.clear
        @osc_esc = false
        @osc_string = true
      when '7' then save_cursor; @state = :ground
      when '8' then restore_cursor; @state = :ground
      when 'H' then @tab_stops << cursor_x; @state = :ground # HTS: set tab stop at cursor
      when 'M' then reverse_index; @state = :ground          # RI
      when 'D' then line_feed; @state = :ground              # IND
      when 'E' then @x = 0; line_feed; @state = :ground      # NEL
      when 'c' then full_reset; @state = :ground             # RIS
      else
        @state = :ground # '=', '>', and anything else: no-op
      end
    end

    # Largest OSC payload (window/icon title etc.) buffered before further bytes
    # are dropped. An unterminated OSC would otherwise grow `@osc_buf` without
    # limit, retaining that capacity for the widget's lifetime. Terminator
    # scanning continues past the cap, so state recovery is unaffected; an
    # over-long title is simply truncated.
    OSC_MAX = 4096

    private def handle_osc(c : Char) : Nil
      if @osc_esc
        @osc_esc = false
        if c == '\\' # ST = ESC \
          finish_osc
          @state = :ground
          return
        end
        # A lone ESC not forming ST (ESC \) was part of the string payload;
        # restore it before handling the current byte so an OSC containing a
        # literal ESC + non-`\` isn't silently corrupted — but only for a real
        # OSC; a discarded DCS/SOS/PM/APC payload is never materialized.
        #
        # NOTE: per the strict VT500 state machine a lone ESC also aborts a
        # DCS/SOS/PM/APC string outright. That refinement was deliberately
        # NOT applied here: real-world DCS passthrough (e.g. tmux's
        # `DCS tmux; <doubled-ESC payload> ST` wrapper) relies on exactly
        # this "ESC not forming ST stays in the string" behavior — aborting
        # on the inner ESC would end the DCS early and leak the remainder of
        # the wrapped payload to the grid, regressing bug #94's own repro.
        @osc_buf << '\e' if !@osc_string && @osc_buf.bytesize < OSC_MAX
      end
      case c.ord
      when 0x07
        # BEL only terminates a *real* OSC (the xterm extension). Inside a
        # DCS/SOS/PM/APC string (`@osc_string`) it is inert payload — only
        # ST (or CAN/SUB) ends the string — so keep scanning.
        unless @osc_string
          finish_osc
          @state = :ground
        end
      when 0x18, 0x1a
        # CAN/SUB abort the string sequence from any state (VT500 "anywhere"
        # transition) and produce no output. `@osc_buf` is cleared on the
        # next OSC/DCS entry, so abandoning it here leaks nothing.
        @state = :ground
      when 0x1b then @osc_esc = true
        # A DCS/SOS/PM/APC string (`@osc_string`) is swallowed only to find its
        # ST/BEL terminator — its payload is discarded, never parsed as a title.
        # Don't append it to `@osc_buf`: otherwise a long payload (e.g. a
        # full-screen sixel image) grows the buffer, whose capacity is then
        # retained for the widget's lifetime. Still run the ESC-pending logic
        # above so ST is detected.
      else @osc_buf << c if !@osc_string && @osc_buf.bytesize < OSC_MAX
      end
    end

    # :nodoc: bytes currently buffered for the pending OSC/DCS string. Exposed
    # for tests asserting a discarded DCS/SOS/PM/APC payload is not accumulated.
    def osc_buffer_size : Int32
      @osc_buf.size.to_i
    end

    private def finish_osc : Nil
      # A DCS/SOS/PM/APC string was only swallowed for its terminator; never
      # interpret its payload as an OSC title.
      return if @osc_string
      # Only window/icon title (codes 0, 1, 2) are acted on. Parse the numeric
      # code in place from the raw buffer (like `csi_param_raw`) and materialize
      # the title `String` only when the code is a title code AND a handler is
      # installed — so OSC 7/133 (cwd/prompt marks modern shells spam) and the
      # no-listener case allocate nothing.
      handler = @on_title
      return unless handler
      ptr = @osc_buf.buffer
      size = @osc_buf.bytesize
      code = 0
      ndigits = 0
      idx = 0
      while idx < size
        b = ptr[idx]
        break if b == ';'.ord
        return unless '0'.ord <= b <= '9'.ord         # non-numeric code ⇒ not a title
        code = code * 10 + (b - '0'.ord) if code <= 9 # cap accumulation (only 0/1/2 matter; avoids overflow)
        ndigits += 1
        idx += 1
      end
      # Need at least one digit, a `;` terminator (idx < size), and a title code.
      return unless ndigits > 0 && idx < size && (code == 0 || code == 1 || code == 2)
      handler.call(String.new(ptr + idx + 1, size - idx - 1))
    end

    # Largest CSI parameter buffer retained before further parameter bytes are
    # dropped (mirrors OSC_MAX). xterm caps well under this; the exact value only
    # bounds worst-case memory on an unterminated/adversarial sequence.
    CSI_MAX = 4096

    private def handle_csi(c : Char) : Nil
      o = c.ord
      # A leading byte in 0x3c-0x3f (`<` `=` `>` `?`) is the private/intermediate
      # prefix — capture it instead of folding it into the numeric parameters.
      if @csi_prefix.nil? && @csi_buf.empty? && 0x3c <= o <= 0x3f
        @csi_prefix = c
        @csi_private = (c == '?')
        return
      end
      if o >= 0x20 && o <= 0x2f
        # Intermediate byte (space through '/'): mark the sequence and keep it
        # out of the numeric parameter buffer. `dispatch_csi` ignores any
        # sequence carrying one (see `@csi_intermediate`).
        @csi_intermediate = true
        return
      end
      if o >= 0x30 && o <= 0x3f
        # Cap the parameter buffer like OSC_MAX: an unterminated CSI (a buggy
        # child, or `ESC [` followed by megabytes of digit/`;`/`:` data) would
        # otherwise grow @csi_buf without limit, retaining that capacity for the
        # widget's lifetime. Terminator scanning below is unchanged, so state
        # recovery is unaffected — an over-long field is simply truncated.
        @csi_buf.write_byte(o.to_u8) if @csi_buf.bytesize < CSI_MAX # parameter bytes (digits, ';', ':', private markers)
        return
      end
      dispatch_csi c # final byte (0x40..0x7e)
      @state = :ground
    end

    # ───────────────────────── CSI dispatch ─────────────────────────

    # Largest value a single CSI parameter field can carry (xterm's own limit).
    # The digit-accumulating parsers below clamp each field to this, so a huge
    # but *valid* parameter (e.g. `CSI 2147483639 C`) can't make a handler's
    # arithmetic (`@x + n`, `@y + n`, `@scroll_top + row`, `@x + n - 1`)
    # overflow `Int32` — an `OverflowError` escaping `#feed` looks like EOF to
    # the reader fiber and permanently wedges the widget. Clamping (rather than
    # zeroing) matches xterm, which caps oversized parameters at 65535.
    PARAM_FIELD_MAX = 65535

    # The n-th `;`-separated parameter in `@csi_buf` (0-based), parsed in place,
    # or nil when there is no n-th field. An empty/non-numeric field reads as 0.
    # No allocation.
    private def csi_param_raw(n : Int32) : Int32?
      field = 0
      result : Int32? = nil
      # `#each_csi_param` yields the fields at indices 0, 1, 2, … in order; the
      # block inlines, so capturing the one at index `n` adds no allocation.
      each_csi_param do |v|
        result = v if field == n
        field += 1
      end
      result
    end

    # The n-th parameter, falling back to `default` when absent or zero (the VT
    # "missing/zero ⇒ default" rule).
    private def param(n : Int32, default : Int32) : Int32
      v = csi_param_raw n
      (v.nil? || v == 0) ? default : v
    end

    # The n-th parameter as a raw code (absent ⇒ 0), for the handlers that want
    # the literal value rather than the missing-⇒-default rule (`J`/`K`/`n`/`c`).
    private def param0(n : Int32) : Int32
      csi_param_raw(n) || 0
    end

    # Yields every `;`-separated parameter in turn. Always yields at least one
    # value (0 for an empty buffer).
    private def each_csi_param(& : Int32 ->) : Nil
      ptr = @csi_buf.buffer
      size = @csi_buf.bytesize
      val = 0
      bad = false
      idx = 0
      while idx < size
        b = ptr[idx].to_i
        if b == ';'.ord
          yield(bad ? 0 : val)
          val = 0
          bad = false
        elsif '0'.ord <= b <= '9'.ord
          # Clamp to the field maximum (see `csi_param_raw`).
          val = Math.min(val * 10 + (b - '0'.ord), PARAM_FIELD_MAX)
        else
          bad = true
        end
        idx += 1
      end
      yield(bad ? 0 : val)
    end

    # CUU/CPL: move the cursor up *n* rows, stopping at the scroll region's top
    # margin when the cursor starts at or below it (matching xterm's `CursorUp`),
    # else at the top of the window. The clamp keeps CUU from walking out of the
    # scroll region.
    private def cursor_up(n : Int32) : Nil
      lo = @y >= @scroll_top ? @scroll_top : 0
      @y = Math.max(lo, @y - n)
    end

    # CUD/CNL: mirror of `#cursor_up` — move down *n* rows, stopping at the scroll
    # region's bottom margin (when at or above it) else the window bottom.
    private def cursor_down(n : Int32) : Nil
      hi = @y <= @scroll_bottom ? @scroll_bottom : @rows - 1
      @y = Math.min(hi, @y + n)
    end

    # Moves the cursor to a 0-based row, honouring origin mode: when set, the row
    # is relative to the scroll region's top and clamped inside the region.
    private def set_row(row : Int32) : Nil
      @y = if @origin_mode
             clamp(@scroll_top + row, @scroll_top, @scroll_bottom)
           else
             clamp(row, 0, @rows - 1)
           end
    end

    # ameba:disable Metrics/CyclomaticComplexity
    private def dispatch_csi(c : Char) : Nil
      # An intermediate byte (0x20-0x2f) makes this a different command from the
      # bare final: `CSI … $ r` (DECCARA) is not DECSTBM `r`, `CSI … SP @` (SL)
      # is not ICH `@`. None of the finals below take an intermediate, so a
      # sequence carrying one is not one we implement — ignore it rather than
      # execute the wrong command on its parameters.
      return if @csi_intermediate
      case c
      when 'A' then cursor_up(param(0, 1)); @wrap_pending = false
      # CUD ('B') and its ECMA-48 twin VPR ('e', Vertical-Position-Relative) both
      # move the cursor down; xterm maps VPR straight onto CursorDown.
      when 'B', 'e' then cursor_down(param(0, 1)); @wrap_pending = false
      # CUF ('C') and its ECMA-48 twin HPR ('a', Horizontal-Position-Relative)
      # both move the cursor right; xterm maps HPR straight onto CursorForward.
      when 'C', 'a' then @x = Math.min(@cols - 1, @x + param(0, 1)); @wrap_pending = false
      when 'D'      then @x = Math.max(0, @x - param(0, 1)); @wrap_pending = false
      when 'E'      then @x = 0; cursor_down(param(0, 1)); @wrap_pending = false
      when 'F'      then @x = 0; cursor_up(param(0, 1)); @wrap_pending = false
      when 'G', '`' then @x = clamp(param(0, 1) - 1, 0, @cols - 1); @wrap_pending = false
      when 'd'      then set_row(param(0, 1) - 1); @wrap_pending = false
      when 'H', 'f'
        set_row(param(0, 1) - 1)
        @x = clamp(param(1, 1) - 1, 0, @cols - 1)
        @wrap_pending = false
      when 'J' then erase_display(param0(0))
      when 'K' then erase_line(param0(0))
      when 'L' then insert_lines(param(0, 1))
      when 'M' then delete_lines(param(0, 1))
      when 'P' then delete_chars(param(0, 1))
      when '@' then insert_chars(param(0, 1))
      when 'X' then erase_chars(param(0, 1))
        # SU/SD are only the *plain* `CSI Ps S` / `CSI Ps T`. A prefixed form is a
        # different command that must NOT scroll: `CSI ? Pi;Pa;Pv S` is XTSMGRAPHICS
        # (a common sixel-capability probe at startup) and `CSI > Pm T` resets xterm
        # title modes. Without the gate, `param(0, 1)` read the probe's first field
        # and scrolled the live screen (e.g. `\e[?2;1;0S` → `scroll_up` twice).
        # Same `@csi_prefix.nil?` gate as SGR/DECSTBM/SCOSC/DA.
      when 'S' then scroll_region_times(param(0, 1)) { scroll_up } if @csi_prefix.nil?   # SU
      when 'T' then scroll_region_times(param(0, 1)) { scroll_down } if @csi_prefix.nil? # SD
      when 'b' then repeat_last(param(0, 1))                                             # REP
      when 'I' then forward_tab(param(0, 1)); @wrap_pending = false                      # CHT
      when 'Z' then back_tab(param(0, 1))                                                # CBT
      when 'g' then tab_clear(param0(0))                                                 # TBC
      when 'm'
        # Only a *plain* CSI (no prefix) is SGR. A prefixed form like
        # `CSI > 4 ; 2 m` is xterm's modifyOtherKeys (emitted by vim/neovim/tmux
        # at startup), NOT a colour/style change — `apply_sgr` would misread its
        # `4` as SGR underline.
        apply_sgr if @csi_prefix.nil?
      when 'r'
        # Only a *plain* `CSI Pt ; Pb r` is DECSTBM (set scroll region). The
        # private form `CSI ? Pm r` is XTRESTORE (restore DEC private modes,
        # counterpart to the `CSI ? Pm s` XTSAVE the 's' handler ignores). Saved
        # modes aren't tracked, so the restore is a no-op, but it must NOT be
        # mistaken for DECSTBM (which would misread e.g. `CSI ? 7 r`'s `7` as a
        # top margin) — gate on the plain-CSI `@csi_prefix.nil?`.
        top = param(0, 1) - 1
        # xterm *clamps* an over-large bottom margin to the last row instead of
        # rejecting the request. Rejecting it left a stale region in place — e.g.
        # a child emitting `CSI 1;<oldrows> r` before processing SIGWINCH had its
        # DECSTBM dropped.
        bot = Math.min(param(1, @rows) - 1, @rows - 1)
        if @csi_prefix.nil? && top < bot
          @scroll_top = Math.max(0, top)
          @scroll_bottom = bot
          @x = 0
          @y = @origin_mode ? @scroll_top : 0 # DECSTBM homes the cursor
          @wrap_pending = false
        end
        # SM/RM are only the *plain* `CSI Pm h/l` (ANSI modes) or the DEC private
        # `CSI ? Pm h/l`. Any other prefix is a different command — notably
        # ANSI.SYS's `CSI = Ps h` (window mode, common in .ans art files) — and
        # must NOT be dispatched as plain SM: its parameter would be misread as
        # an ANSI mode (`CSI = 4 h` → IRM insert mode, garbling all later output).
        # Same prefix gate as SGR/DECSTBM/SCOSC/DA.
      when 'h' then set_mode true if @csi_prefix.nil? || @csi_private
      when 'l' then set_mode false if @csi_prefix.nil? || @csi_private
      when 's', 'u'
        # SCOSC/SCORC (save/restore cursor) are only the *plain* `CSI s` / `CSI u`.
        # A prefixed form must NOT move the cursor: the Kitty keyboard protocol —
        # negotiated by neovim, fish, kakoune, … at startup — pushes/pops/queries
        # its flags with `CSI > Pn u`, `CSI < Pn u`, `CSI = Pn ; Pn u` and
        # `CSI ? u`. Gating only on `@csi_private` (the `?` prefix) let `>`/`<`/`=`
        # fall through to `restore_cursor`, yanking the cursor to the last saved
        # position on a Kitty-keyboard toggle. Same `@csi_prefix.nil?` gate as SGR.
        if @csi_prefix.nil?
          c == 's' ? save_cursor : restore_cursor
        end
      when 'n' then device_status(param0(0))
      when 'c'
        if param0(0) == 0
          case @csi_prefix
          when nil then respond("\e[?6c")     # primary DA  (CSI c)   — VT102
          when '>' then respond("\e[>0;0;0c") # secondary DA (CSI > c) — VT100, ver 0
          # tertiary (`=`) / unknown prefix: not answered
          end
        end
      when 'x'
        # DECREQTPARM (`CSI Ps x`, plain only): report terminal parameters. Only
        # Ps 0 ("please report, unsolicited allowed") and Ps 1 ("report,
        # solicited only") get a DECREPTPARM reply; the report's `sol` field is
        # Ps+2 (2 or 3). Remaining fields mirror xterm's fixed reply: no parity,
        # 8 bits, 38.4k xspeed/rspeed, clock-multiplier 1, no STP flags. Without
        # this, vttest's "Request Terminal Parameters" reports "Bad format".
        if @csi_prefix.nil?
          req = param0(0)
          respond("\e[#{req + 2};1;1;128;128;1;0x") if req == 0 || req == 1
        end
      else
        # Unimplemented final byte — ignored.
      end
    end

    private def set_mode(on : Bool) : Nil
      unless @csi_private
        # ANSI (non-private) modes. IRM (4) is the only one acted on: toggles
        # insert/replace mode (terminfo `smir`/`rmir`), consumed in `#print_char`.
        # Other standard ANSI modes (e.g. LNM 20) are ignored.
        each_csi_param { |mode| @insert_mode = on if mode == 4 }
        return
      end
      each_csi_param do |mode|
        next if set_mouse_mode(mode, on)
        case mode
        when 25       then @cursor_hidden = !on # DECTCEM
        when 47, 1047 then on ? enter_alt(false) : leave_alt(false)
        when 1048     then on ? save_cursor : restore_cursor # save/restore cursor (as DECSC/DECRC), no buffer switch
        when 1049     then on ? enter_alt(true) : leave_alt(true)
        when 6 # DECOM (origin mode): cursor homes to the (possibly relative) origin
          @origin_mode = on
          @x = 0
          @y = on ? @scroll_top : 0
          @wrap_pending = false
        when 2004 then @bracketed_paste = on
        when 1004 then @focus_reporting = on
        when 7 # DECAWM (autowrap): turning it off cancels any pending wrap too
          @autowrap = on
          @wrap_pending = false unless on
        else
          # 1 (DECCKM), 12 (cursor blink), 1000-series already handled … ignored.
        end
      end
    end

    # Mouse tracking (X10/1000-series) and coordinate-encoding modes; returns
    # false for non-mouse modes so `set_mode` handles them.
    private def set_mouse_mode(mode, on : Bool) : Bool
      case mode
      when    9 then @mouse_tracking = on ? 9 : 0    # X10
      when 1000 then @mouse_tracking = on ? 1000 : 0 # normal (press/release)
      when 1002 then @mouse_tracking = on ? 1002 : 0 # button-event
      when 1003 then @mouse_tracking = on ? 1003 : 0 # any-event
      # Mouse coordinate encodings: disabling one only downgrades to X10 when
      # it is the *active* one — xterm ignores a reset of a non-active
      # protocol. Without the check, a child enabling SGR (1006) and then
      # defensively resetting 1005 would drop the widget back to X10 framing
      # while the child still parses SGR (garbage keys, coords > 223 corrupt).
      when 1005 then on ? (@mouse_encoding = MouseEncoding::Utf8) : (@mouse_encoding = MouseEncoding::Normal if @mouse_encoding.utf8?)
      when 1006 then on ? (@mouse_encoding = MouseEncoding::Sgr) : (@mouse_encoding = MouseEncoding::Normal if @mouse_encoding.sgr?)
      when 1015 then on ? (@mouse_encoding = MouseEncoding::Urxvt) : (@mouse_encoding = MouseEncoding::Normal if @mouse_encoding.urxvt?)
      else           return false
      end
      true
    end

    # Whether the child has requested mouse reporting.
    def mouse_enabled? : Bool
      @mouse_tracking != 0
    end
  end
end
