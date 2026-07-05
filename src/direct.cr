require "./screen"

module Crysterm
  # Inline styled output — the notcurses *direct mode* analogue (`direct.h` /
  # `src/lib/direct.c`). Emits color, styling, cursor moves and box drawing into
  # a **normal scrolling terminal**, without entering the alternate buffer or
  # running a render loop. Drop-in for colorizing an ordinary CLI tool.
  #
  # Unlike `Window` (the full-screen surface), `Direct` owns no cell buffer and
  # does no damage tracking: the caller drives output and `Direct` formats it,
  # synchronously. It *has-a* `Screen` (the device — IO, `Tput`, color depth)
  # and reuses the very same color/SGR down-reduction pipeline the renderer uses
  # (`Screen.code2attr_to` + `Colors.sgr_color_to`), so a 16- or 256-color
  # terminal gets the same faithful palette reduction here as under `Window`.
  #
  # ```
  # d = Crysterm::Direct.new
  # d.print "hello, ", fg: "green", bold: true
  # d.print "colored world\n", fg: 0xff8800
  # d.box 0, 0, 3, 20, fg: "blue"
  # d.flush
  # ```
  #
  # Cursor bookkeeping without a cell buffer: absolute moves (`#move_yx`, `#box`)
  # and relative moves (`#cursor_up`/`#down`/`#left`/`#right`) are delegated to
  # `Tput`, which keeps its own `{x, y}` shadow and clamps to the screen — we add
  # none of our own.
  #
  # NOTE: like `Window`, a `Direct` built with no explicit `output:` follows the
  # `screen.headless` convention (`Crysterm.headless?`) — when STDOUT is **not** a
  # tty (piped/redirected) it defaults to an in-memory sink and emits nothing to
  # the pipe. To colorize output destined for a pager or file
  # (`mytool | less -R`), pass `output: STDOUT` explicitly.
  class Direct
    # The physical terminal/device backing this direct-mode session. Owns IO,
    # `Tput`, and color depth; reused wholesale (no `Window`, no render loop).
    getter screen : Screen

    # Device concerns delegated to the `Screen`.
    delegate tput, output, colors, truecolor?, to: @screen

    # Scratch buffer reused for building each SGR sequence (`code2attr_to` needs
    # a seekable `IO::Memory`). Direct mode is not a hot path, but reusing one
    # buffer keeps per-`print` allocation off the caller's back.
    @sgr_buf = IO::Memory.new

    def initialize(
      input : IO? = nil,
      output : IO? = nil,
      error : IO? = nil,
      terminfo : Bool | Unibilium = true,
      # An already-built device may be adopted directly (mirrors `Window`).
      screen : Screen? = nil,
    )
      @screen = screen || Screen.new(
        input: input || (Crysterm.headless? ? IO::Memory.new : STDIN),
        output: output || (Crysterm.headless? ? IO::Memory.new : STDOUT),
        error: error || (Crysterm.headless? ? IO::Memory.new : STDERR),
        terminfo: terminfo,
      )

      # Adopt the terminal's size so `#dim_x`/`#dim_y` are meaningful (no-op for
      # an explicitly-sized/headless device).
      @screen.adopt_terminal_size

      # Run the live capability probe `Screen.new` skips (`probe: false`). Direct
      # mode has no input listen fiber, so the synchronous round-trip races
      # nothing; it can upgrade the terminal to confirmed truecolor, so SGR
      # emission reduces to the right depth. No-ops on a non-tty / when disabled.
      @screen.probe!
    end

    # Terminal width in cells (columns).
    def dim_x : Int32
      @screen.width
    end

    # Terminal height in cells (rows).
    def dim_y : Int32
      @screen.height
    end

    # Writes *str* styled with the given colors/attributes, then resets styling
    # (`\e[0m`) so following output is clean. *fg*/*bg* accept an `Int32` RGB
    # value (or `-1` for the terminal default), a color name/hex `String`, or
    # `nil` (default). Colors are reduced to the terminal's depth on the way out.
    def print(
      str,
      fg = nil,
      bg = nil,
      bold = false,
      italic = false,
      underline = false,
      blink = false,
      reverse = false,
      strike = false,
      invisible = false,
    ) : self
      code = build_code fg, bg, bold, italic, underline, blink, reverse, strike, invisible
      emit_styled(code) { |o| o << str }
      self
    end

    # Writes a single character styled like `#print`.
    def putc(
      char : Char,
      fg = nil,
      bg = nil,
      bold = false,
      italic = false,
      underline = false,
      blink = false,
      reverse = false,
      strike = false,
      invisible = false,
    ) : self
      code = build_code fg, bg, bold, italic, underline, blink, reverse, strike, invisible
      emit_styled(code) { |o| o << char }
      self
    end

    # Sets a *persistent* style for subsequent raw output — the stateful
    # counterpart to `#print`. Emits the SGR sequence and leaves it in effect
    # until `#reset_styles` (or another `#set_style`). Use when interleaving with
    # direct writes to `#output`; use `#print` for one-shot self-contained spans.
    def set_style(
      fg = nil,
      bg = nil,
      bold = false,
      italic = false,
      underline = false,
      blink = false,
      reverse = false,
      strike = false,
      invisible = false,
    ) : self
      code = build_code fg, bg, bold, italic, underline, blink, reverse, strike, invisible
      @sgr_buf.clear
      Screen.code2attr_to @sgr_buf, code, colors
      @screen.output.write @sgr_buf.to_slice
      self
    end

    # Clears any style set by `#set_style` (SGR reset).
    def reset_styles : self
      @screen.output << "\e[0m"
      self
    end

    # Moves the cursor to absolute row *y*, column *x* (0-based). Delegated to
    # `Tput`, which clamps to the screen and tracks the position.
    def move_yx(y : Int, x : Int) : self
      tput.cursor_pos y, x
      self
    end

    # Moves the cursor up *n* rows.
    def cursor_up(n : Int = 1) : self
      tput.cursor_up n
      self
    end

    # Moves the cursor down *n* rows.
    def cursor_down(n : Int = 1) : self
      tput.cursor_down n
      self
    end

    # Moves the cursor right *n* columns.
    def cursor_right(n : Int = 1) : self
      tput.cursor_forward n
      self
    end

    # Moves the cursor left *n* columns.
    def cursor_left(n : Int = 1) : self
      tput.cursor_backward n
      self
    end

    # Moves the cursor **relative to its current position**: *dy* rows (negative
    # = up) and *dx* columns (negative = left). `relative(-2, -2)` moves two rows
    # up and two columns left. The shared "relative addressing" primitive — it
    # reuses Tput's tracked position, so callers never compute absolute
    # coordinates. See `CursorAnchor#relative` for the placement-math counterpart.
    def relative(dy : Int = 0, dx : Int = 0) : self
      tput.rmove dx, dy
      self
    end

    # A `CursorAnchor` over this session's terminal, so callers can compute
    # placement relative to the live cursor (`anchor.relative(1, 0)` = the line
    # below) using the same abstraction inline `Window`s and the completer use.
    def cursor_anchor : CursorAnchor
      TerminalCursorAnchor.new @screen
    end

    # Emits *n* CRLF line breaks (inline mode scrolls the real terminal).
    def newline(n : Int = 1) : self
      n.times { @screen.output << "\r\n" }
      self
    end

    # Draws a horizontal run of *len* cells using *ch*, styled like `#print`.
    def hline(len : Int32, ch : Char = '─', fg = nil, bg = nil) : self
      print ch.to_s * len, fg: fg, bg: bg
      self
    end

    # Draws a vertical run of *len* cells using *ch*, styled like `#print`.
    # Advances downward one cell per character (cursor returns under the start).
    def vline(len : Int32, ch : Char = '│', fg = nil, bg = nil) : self
      len.times do |i|
        putc ch, fg: fg, bg: bg
        if i < len - 1
          cursor_down 1
          cursor_left 1
        end
      end
      self
    end

    # Draws a *w*×*h* box with its top-left corner at row *y*, column *x*
    # (0-based, absolute). Uses Unicode line-drawing characters, or ASCII
    # (`+`/`-`/`|`) when *ascii* is true. Styled with *fg*/*bg* like `#print`.
    def box(y : Int, x : Int, h : Int32, w : Int32, fg = nil, bg = nil, ascii = false) : self
      return self if w < 2 || h < 2
      tl, tr, bl, br, hz, vt =
        if ascii
          {'+', '+', '+', '+', '-', '|'}
        else
          {'┌', '┐', '└', '┘', '─', '│'}
        end

      move_yx y, x
      print "#{tl}#{hz.to_s * (w - 2)}#{tr}", fg: fg, bg: bg
      (1...(h - 1)).each do |i|
        move_yx y + i, x
        putc vt, fg: fg, bg: bg
        move_yx y + i, x + w - 1
        putc vt, fg: fg, bg: bg
      end
      move_yx y + h - 1, x
      print "#{bl}#{hz.to_s * (w - 2)}#{br}", fg: fg, bg: bg
      self
    end

    # Flushes any buffered output to the terminal.
    def flush : self
      @screen.output.flush
      self
    end

    # Resets styling and flushes — call when done with a direct-mode session so
    # no stray SGR state leaks into the shell prompt.
    def reset : self
      reset_styles
      flush
      self
    end

    # Packs *fg*/*bg* + attribute flags into the `Int64` attr word the SGR
    # pipeline consumes. Colors are resolved to native RGB (or the `-1` default).
    private def build_code(fg, bg, bold, italic, underline, blink, reverse, strike, invisible) : Int64
      flags = 0_i64
      flags |= Attr::BOLD if bold
      flags |= Attr::ITALIC if italic
      flags |= Attr::UNDERLINE if underline
      flags |= Attr::BLINK if blink
      flags |= Attr::REVERSE if reverse
      flags |= Attr::STRIKE if strike
      flags |= Attr::INVISIBLE if invisible
      Attr.pack flags, Attr.pack_color(Colors.convert_cached(fg)), Attr.pack_color(Colors.convert_cached(bg))
    end

    # Emits *code*'s SGR sequence (reduced to the terminal's color depth), then
    # the caller's payload, then a reset — but only wraps when the style is
    # non-empty, so plain unstyled text emits no escapes at all.
    private def emit_styled(code : Int64, & : IO -> Nil) : Nil
      dest = @screen.output
      @sgr_buf.clear
      Screen.code2attr_to @sgr_buf, code, colors
      styled = @sgr_buf.size > 0
      dest.write @sgr_buf.to_slice if styled
      yield dest
      dest << "\e[0m" if styled
    end
  end
end
