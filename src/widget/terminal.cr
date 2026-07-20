require "../widget_terminal_pty"
require "../widget_terminal_emulator"

module Crysterm
  class Widget
    # A terminal-emulator widget: runs a child program (a shell by default)
    # inside a pseudo-terminal and renders its output as a live, scrollable
    # window.
    #
    # `Crysterm::Pty` spawns and talks to the child via a PTY, and
    # `Crysterm::TerminalEmulator` parses its byte stream into a cell grid. This
    # widget wires them to the window: sizes them from its inner area, forwards
    # keystrokes, copies the emulator grid onto `window.lines` each render, and
    # draws the cursor.
    #
    # Usage:
    # ```
    # term = Crysterm::Widget::Terminal.new width: 80, height: 24
    # window.append term
    # term.focus
    # ```
    #
    # Keyboard, mouse and pastes are all forwarded to the child (a paste
    # wrapped in bracketed-paste markers when the child enabled DEC 2004); the
    # emulator supports the alternate window buffer, DEC line-drawing, scroll
    # regions/scrollback, origin mode, and focus reporting. Scrollback is
    # navigable with Shift-PageUp/PageDown, and `Event::ProcessExited` fires
    # (with the exit code) when the child process ends. Not yet implemented:
    # double-width/height *lines*.
    #
    # <!-- widget-examples:capture v1 -->
    # ![Terminal screenshot](../../tests/widget/terminal/terminal.5s.apng)
    # <!-- /widget-examples:capture -->
    class Terminal < Widget
      # A terminal manages its own scrollback; it is not a scrollable Box.
      @scrollable = false

      # The running child process wrapper, or `nil` when an external `handler`
      # supplies the data instead of a spawned process.
      getter pty : Pty? = nil

      # The emulator holding the parsed window grid. `nil` until the first
      # render (needs the resolved inner geometry to size it).
      getter emulator : TerminalEmulator? = nil

      # The most recent window/icon title reported by the child (OSC 0/2).
      property title : String? = nil

      # Cursor shape drawn over the emulator's cursor cell: `Tput::CursorShape::Block`
      # (default), `::Underline`, or `::Line`. `::None` leaves the cell unstyled
      # (the cursor is invisible in the overlay).
      property cursor_shape : Tput::CursorShape

      @shell : String
      @args : Array(String)
      @term_name : String
      @env : Process::Env

      # When set, the widget does not spawn a PTY; instead the block is called
      # with raw input bytes (keystrokes) and the caller feeds output back via
      # `#write`. Used to drive a terminal from a remote socket, recording, etc.
      @handler : Proc(String, Nil)?

      @dattr : Int64 = 0_i64
      @bootstrapped = false

      # Reused scratch buffer for `#encode_mouse`, cleared rather than
      # reallocated per event: avoids an `IO::Memory` on the drag hot path under
      # modes 1002/1003. The returned slice must be consumed before the next
      # event reuses it.
      @mouse_buf = IO::Memory.new

      def initialize(
        *,
        shell : String? = nil,
        args : Array(String) = [] of String,
        cursor_shape : Tput::CursorShape = :block,
        term_name : String? = nil,
        env : Process::Env = nil,
        handler : Proc(String, Nil)? = nil,
        **box,
      )
        @shell = shell || Crysterm::Config.input_shell
        @args = args
        @cursor_shape = cursor_shape
        @term_name = term_name || Crysterm::Config.terminal_term
        @env = env
        @handler = handler

        super **box

        @keys = true
        @input = true
        window?.try &.register_keyable self

        on ::Crysterm::Event::KeyPress, ->on_keypress(::Crysterm::Event::KeyPress)
        on ::Crysterm::Event::Mouse, ->on_mouse(::Crysterm::Event::Mouse)
        on ::Crysterm::Event::Paste, ->on_paste(::Crysterm::Event::Paste)
        on(::Crysterm::Event::FocusIn) { report_focus true }
        on(::Crysterm::Event::FocusOut) { report_focus false }
        on(::Crysterm::Event::Destroy) { kill }
      end

      # Installs the raw-input `handler` (the block form of the `handler:` ctor
      # param) via a block: `term.on_input { |bytes| ... }`.
      #
      # CONSTRAINT: must be called *before the widget bootstraps* (its first
      # render). `@handler` is consumed in `#bootstrap`, which decides there and
      # then whether to spawn a PTY (no handler) or run externally-driven (with
      # one); once bootstrapped the choice is fixed, so a later install would be
      # silently ignored. Raises if the widget has already bootstrapped.
      def on_input(&block : String ->) : Nil
        raise "Widget::Terminal#on_input must be set before the terminal bootstraps (first render)" if @bootstrapped
        @handler = block
      end

      # Feeds output bytes into the emulator directly. Useful with a `handler`
      # (no PTY) to drive the display from an arbitrary source.
      #
      # Bytes written before the widget bootstraps (its first render with a
      # positive inner size — only then does the emulator exist) are buffered
      # and replayed into the emulator at bootstrap: handler-mode data is a
      # stream, so silently dropping the prefix (typically the remote's
      # initial screen state) would corrupt the display irrecoverably.
      def write(data : Bytes | String) : Nil
        bytes = data.is_a?(String) ? data.to_slice : data
        if em = @emulator
          em.feed bytes
        else
          pending = @pending_writes ||= IO::Memory.new
          # Cap the buffer so a widget that never renders (zero inner size)
          # cannot grow it unboundedly; overflow drops the tail, keeping the
          # stream prefix (the part that seeds the initial screen state).
          pending.write(bytes) if pending.size + bytes.size <= PENDING_WRITES_CAP
        end
        request_render
      end

      # Pre-bootstrap `#write` data awaiting the emulator (see `#write`).
      @pending_writes : IO::Memory? = nil

      # Upper bound for `@pending_writes`.
      PENDING_WRITES_CAP = 4 * 1024 * 1024

      # Inner content width/height in cells (box minus border+padding).
      private def term_cols : Int32
        Math.max(0, awidth - ihorizontal)
      end

      private def term_rows : Int32
        Math.max(0, aheight - ivertical)
      end

      private def bootstrap(cols : Int32, rows : Int32) : Nil
        return if @bootstrapped
        @bootstrapped = true

        @dattr = style_to_attr style
        em = TerminalEmulator.new cols, rows, @dattr
        em.on_refresh = -> { request_render; nil }
        em.on_title = ->(t : String) { @title = t; emit ::Crysterm::Event::ContentChanged; nil }
        @emulator = em

        if handler = @handler
          # Externally driven: nothing to spawn. The emulator's solicited replies
          # (DSR cursor-position, DA device-attributes) are child-bound too, so
          # route them to the handler as well — otherwise a child probing the
          # terminal at startup (vim/htop query DA/CPR) waits forever.
          em.output = HandlerSink.new handler
          flush_pending_writes em
          return
        end

        # Advertise the configured TERM to the child. Without this the child
        # inherits the HOST terminal's TERM (e.g. xterm-kitty) and negotiates
        # sequences `TerminalEmulator` does not implement. An explicit TERM
        # already in `@env` wins.
        env = {} of String => String?
        @env.try &.each { |k, v| env[k] = v }
        env["TERM"] = @term_name unless env.has_key?("TERM")
        pty = Pty.new @shell, @args, cols, rows, env
        @pty = pty
        em.output = pty.master # so DSR/DA replies reach the child
        flush_pending_writes em

        # Reader fiber pumps child output into the emulator. Fibers are
        # cooperatively scheduled, so this never races the main loop.
        spawn do
          buf = Bytes.new 8192
          loop do
            n = pty.master.read buf
            break if n == 0
            em.feed buf[0, n]
          rescue
            break
          end
          # Child closed the PTY: reap it, surface exit status, tear down.
          code = pty.reap
          emit ::Crysterm::Event::ProcessExited, code
          # Marshal the real teardown onto the render fiber. It must go through
          # `#destroy`: emitting a bare `Event::Destroy` would leave the widget
          # attached, keyable and focusable while listeners believed it dead, and
          # a later `#destroy` would emit the event twice. `#kill` is idempotent
          # for the already-reaped PTY.
          window?.try &.post { destroy }
        end
      end

      # Replays any pre-bootstrap `#write` data into the freshly built
      # emulator, after its `output` sink is wired (solicited replies from the
      # replayed bytes — DSR/DA probes — must reach the handler/child).
      private def flush_pending_writes(em : TerminalEmulator) : Nil
        if pending = @pending_writes
          @pending_writes = nil
          em.feed pending.to_slice unless pending.empty?
        end
      end

      # Forwards a keystroke to the child as raw bytes. For legacy input,
      # `Event::KeyPress#sequence` carries the original bytes tput read —
      # exactly what the child expects. When the HOST terminal speaks an
      # enhanced keyboard protocol (kitty CSI-u / modifyOtherKeys — enabled by
      # default in `Window#listen`), `sequence` holds enhanced bytes the child
      # never negotiated (Ctrl+C as `\e[99;5u`, Esc as `\e[27u`): forwarded
      # raw, Ctrl+C would never reach the tty line discipline (no SIGINT) and
      # Esc would arrive as junk. Such events are re-encoded to legacy bytes
      # via `KeyEvent#to_legacy_bytes` — before the scrollback match below, so
      # Shift-PageUp/PageDown re-encode to the legacy `;2` forms it expects.
      protected def on_keypress(e : ::Crysterm::Event::KeyPress) : Nil
        return unless focused?

        data =
          if ke = e.key_event
            # No legacy representation (lone modifier press, functional key
            # with no legacy encoding): a legacy terminal would have sent
            # nothing — forward nothing, and leave the event unconsumed.
            ke.to_legacy_bytes || return
          else
            e.sequence.join
          end

        # Shift-PageUp/PageDown share the PageUp/PageDown key but carry a `;2`
        # modifier in their raw sequence; matched here and consumed for
        # scrollback navigation instead of forwarding to the child.
        if em = @emulator
          page = Math.max(1, term_rows - 1)
          case data
          when "\e[5;2~" then scroll(-page); e.accept; request_render; return
          when "\e[6;2~" then scroll(page); e.accept; request_render; return
          end
          # Any real keystroke snaps the view back to the live bottom (xterm UX).
          em.reset_scroll if em.ydisp != em.ybase
        end

        if handler = @handler
          handler.call data
        elsif pty = @pty
          pty.write data
        else
          return
        end

        e.accept
        request_render
      end

      # Forwards pasted text (routed here by the window while focused) to the
      # child, wrapped in bracketed-paste markers when the child has enabled
      # the mode (DECSET 2004) — so a child readline/editor can treat the
      # paste atomically instead of as typed input.
      protected def on_paste(e : ::Crysterm::Event::Paste) : Nil
        return unless focused?

        data = e.content
        if @emulator.try &.bracketed_paste?
          data = "\e[200~#{data}\e[201~"
        end

        if handler = @handler
          handler.call data
        elsif pty = @pty
          pty.write data
        else
          return
        end

        # Like a keystroke, input snaps the view back to the live bottom.
        @emulator.try { |em| em.reset_scroll if em.ydisp != em.ybase }
        e.accept
        request_render
      end

      # Sends a focus/blur report (`ESC[I` / `ESC[O`) to the child when it has
      # enabled focus reporting (DECSET ?1004). Wired to the widget's focus and
      # blur events.
      private def report_focus(gained : Bool) : Nil
        em = @emulator
        return unless em && em.focus_reporting?
        forward_to_child((gained ? "\e[I" : "\e[O").to_slice)
      end

      # Forwards a mouse event to the child when mouse tracking is enabled,
      # encoded in whichever scheme it asked for (normal/SGR/urxvt). No-op when
      # tracking is off, so the window's default click-to-focus/wheel-scroll applies.
      def on_mouse(e : ::Crysterm::Event::Mouse) : Nil
        em = @emulator
        return unless em && em.mouse_enabled?
        # Only forward what the child's active tracking mode asked for;
        # forwarding everything floods a child in normal mode with unrequested
        # motion reports.
        return unless mouse_event_wanted? em, e

        # Coordinates relative to the inner (content) area, 0-based. Rows map
        # through the RENDERED position (mirroring `#draw`), not the layout
        # `atop`: inside a scrolled container `#draw` paints the grid at
        # `lpos.yi` with the clipped-top rows folded into `lpos.base`, so the
        # hit-map must undo exactly that — otherwise every report forwarded to
        # the child is off by the scroll offset. Columns keep the unclipped
        # content origin (`aleft + ileft`), which `#draw` also uses, since
        # horizontal clipping carries no `base`. Falls back to the layout
        # position before the first render (direct `on_mouse` calls have no
        # `@lpos` yet), mirroring `Event::Mouse#local_y`.
        col = e.x - (aleft + ileft)
        row =
          if lp = @lpos
            e.y - (lp.yi + itop) + lp.base
          else
            e.y - (atop + itop)
          end
        return if col < 0 || row < 0 || col >= term_cols || row >= term_rows

        # A click still focuses the terminal; the default path is suppressed by
        # the `accept` below.
        focus if e.action.down? && !focused?

        report = encode_mouse em, e, col, row
        forward_to_child report
        e.accept
        request_render
      end

      # Whether the child's active mouse-tracking mode wants this event. xterm's
      # DECSET modes are progressive: a higher mode is a superset of lower ones.
      # `mouse_tracking` is the live DECSET value (9/1000/1002/1003) parsed.
      private def mouse_event_wanted?(em : TerminalEmulator, e : ::Crysterm::Event::Mouse) : Bool
        case em.mouse_tracking
        when 9 # X10: button presses only (no release, wheel, or motion)
          e.action.down?
        when 1000 # normal (press/release + wheel), but NOT motion
          !e.action.move?
        when 1002 # button-event: motion only while a button is held
          !e.action.move? || e.button != ::Tput::Mouse::Button::None
        else # 1003 (any-event) and any future mode: everything
          true
        end
      end

      # Encodes a normalized `Event::Mouse` into an xterm mouse report, in the
      # child's selected encoding. Returns raw bytes: legacy/normal encoding
      # packs values that may exceed 0x7f, which a UTF-8 `String` would corrupt.
      private def encode_mouse(em : TerminalEmulator, e : ::Crysterm::Event::Mouse, col : Int32, row : Int32) : Bytes
        sgr = em.mouse_encoding.sgr?
        cb = mouse_cb e, sgr
        x1 = col + 1
        y1 = row + 1
        released = e.action.up?

        io = @mouse_buf
        io.clear
        case em.mouse_encoding
        in .sgr?
          io << "\e[<" << cb << ';' << x1 << ';' << y1 << (released ? 'm' : 'M')
        in .urxvt?
          io << "\e[" << (cb + 32) << ';' << x1 << ';' << y1 << 'M'
        in .normal?, .utf8? # utf8 handled as normal, best-effort
          io << "\e[M"
          io.write_byte (cb + 32).clamp(0, 255).to_u8
          io.write_byte (x1 + 32).clamp(0, 255).to_u8
          io.write_byte (y1 + 32).clamp(0, 255).to_u8
        end
        io.to_slice
      end

      # Reconstructs the xterm "Cb" button byte. In SGR the button is preserved
      # on release (trailing `m` signals it); legacy encoding uses generic "button 3".
      private def mouse_cb(e : ::Crysterm::Event::Mouse, sgr : Bool) : Int32
        bits = case e.button
               when ::Tput::Mouse::Button::Left   then 0
               when ::Tput::Mouse::Button::Middle then 1
               when ::Tput::Mouse::Button::Right  then 2
               else                                    3
               end

        cb = case e.action
             when ::Tput::Mouse::Action::WheelUp   then 64
             when ::Tput::Mouse::Action::WheelDown then 65
             when ::Tput::Mouse::Action::Move      then 32 + bits
             when ::Tput::Mouse::Action::Up        then sgr ? bits : 3
             else                                       bits # Down
             end

        cb += 4 if e.shift?
        cb += 8 if e.meta?
        cb += 16 if e.ctrl?
        cb
      end

      # Sends raw bytes to the child (PTY, or the external handler as a String).
      private def forward_to_child(data : Bytes) : Nil
        if handler = @handler
          handler.call String.new(data)
        elsif pty = @pty
          pty.write data
        end
      end

      # Renders via the base implementation, then overlays the emulator grid and
      # cursor onto the inner area.
      def render(with_children = true)
        coords = super
        return coords unless coords

        cols = term_cols
        rows = term_rows
        if cols > 0 && rows > 0
          if @bootstrapped
            if (em = @emulator) && (em.cols != cols || em.rows != rows)
              em.resize cols, rows
              @pty.try &.resize(cols, rows)
            end
          else
            bootstrap cols, rows
          end
        end

        draw coords
        coords
      end

      private def draw(coords) : Nil
        em = @emulator
        return unless em

        # Keep the emulator's "default" attr in sync with the live style so
        # default-coloured cells track theme changes.
        @dattr = style_to_attr style
        em.default_attr = @dattr

        lines = window.lines

        xi = coords.xi + ileft
        xl = coords.xl - iright
        yi = coords.yi + itop
        yl = coords.yl - ibottom

        # When an ancestor clips this widget, `coords` moves `coords.xi`/`coords.yi`
        # inward to the clip edge and folds the clipped-top row count into
        # `coords.base`. Rows must map through `coords.base` and columns through
        # the unclipped content origin — the true position of emulator column 0,
        # since horizontal clipping has no `base` — or a partially clipped
        # terminal shows its top-left corner instead of the correct grid region.
        origin_x = aleft + ileft

        disp = em.ydisp
        focused = window.focused == self
        cur_y = yi + em.cursor_y - coords.base
        cur_x = origin_x + em.cursor_x
        # The cursor is hidden while the user is scrolled back into history, and
        # skipped when it maps outside the (possibly clipped) visible viewport.
        show_cursor = focused && !em.cursor_hidden? && disp == em.ybase &&
                      cur_y >= Math.max(yi, 0) && cur_y < yl &&
                      cur_x >= Math.max(xi, 0) && cur_x < xl
        full_unicode = window.full_unicode_effective?

        y = Math.max yi, 0
        while y < yl
          line = lines[y]?
          break unless line
          src = em.lines[disp + coords.base + (y - yi)]?
          break unless src

          cursor_col = (show_cursor && y == cur_y) ? cur_x : -1

          x = Math.max xi, 0
          while x < xl
            cell = line[x]?
            break unless cell
            scell = src[x - origin_x]?
            break unless scell

            attr = scell.attr
            ch = scell.char
            # The emulator parks a NUL in the trailing half of a wide glyph;
            # render it blank. In full-unicode mode the wide-glyph branch below
            # claims the following cell as a real continuation, skipping this.
            ch = ' ' if ch == TerminalEmulator::CONTINUATION

            if x == cursor_col
              attr, ch = apply_cursor attr, ch
            end

            # A wide (2-column) glyph whose continuation cell cannot be claimed —
            # past the content region or absent from the window row — is blanked
            # to a space, upholding the invariant "a width-2 cell is always
            # followed by an in-region continuation" that the flush code relies on
            # (mirrors the end-of-line safeguard in widget_rendering.cr:540-553).
            # Terminal overrides #draw with its own loop, so it needs its own copy;
            # without it a bare wide lead — e.g. one stranded in the last column by
            # a column-shrink resize — would over-claim and paint across the
            # widget's edge into the neighbouring cell. Must stay the exact
            # complement of the continuation-claim block below.
            if full_unicode && ::Crysterm::Unicode.width(ch) == 2 &&
               (x + 1 >= xl || line[x + 1]?.nil?)
              ch = ' '
            end

            if cell != {attr, ch}
              cell.attr = attr
              cell.char = ch
              line.dirty = true
            end

            # Wide glyph: claim the following window cell as its continuation so
            # the window grid stays 1 cell == 1 terminal column. This holds even
            # when the cursor sits on the lead half — `attr` already carries the
            # cursor styling — so both columns are still consumed.
            if full_unicode && (nxt = line[x + 1]?) &&
               x + 1 < xl && ::Crysterm::Unicode.width(ch) == 2
              nxt_attr = attr
              # With the cursor on the TRAILING half of a wide glyph, `x += 2`
              # would skip its column and leave it invisible; carry the cursor
              # styling onto the continuation cell instead.
              if x + 1 == cursor_col
                nxt_attr, _ = apply_cursor attr, ' '
              end
              nxt.attr = nxt_attr
              nxt.continuation!
              line.dirty = true
              x += 2
              next
            end

            x += 1
          end

          y += 1
        end
      end

      # Produces the {attr, char} for the cell under the cursor, per `cursor_shape`.
      private def apply_cursor(attr : Int64, ch : Char) : {Int64, Char}
        # `when`, not `in`: Tput::CursorShape has aliased members (Box = Block,
        # HBar = Underline, ...) which defeat exhaustiveness checking.
        case @cursor_shape
        when .underline?
          {Attr.pack(Attr.flags(attr) | Attr::UNDERLINE, Attr.fg(attr), Attr.bg(attr)), ch}
        when .block?
          # Invert the cell. Toggle (not OR) REVERSE, mirroring the B16-05 fix in
          # `window_cursor.cr`: a cell the child already rendered reversed (SGR 7 —
          # selections, status bars, hlsearch matches) must flip back to normal
          # video so the cursor stays visible instead of no-op'ing into invisibility.
          {Attr.pack(Attr.flags(attr) ^ Attr::REVERSE, Attr.fg(attr), Attr.bg(attr)), ch}
        else
          # Line: the host terminal draws the real beam in this column, so both
          # `ch` and `attr` must be preserved rather than overwritten with '│'.
          # None likewise leaves the cell untouched.
          {attr, ch}
        end
      end

      # ── scrollback controls (delegate to the emulator) ──

      def scroll_to(offset : Int32) : Nil
        @emulator.try &.scroll_to(offset)
        emit ::Crysterm::Event::Scroll
      end

      def scroll(offset : Int32) : Nil
        @emulator.try &.scroll(offset)
        emit ::Crysterm::Event::Scroll, offset
      end

      def reset_scroll : Nil
        @emulator.try &.reset_scroll
        emit ::Crysterm::Event::Scroll
      end

      def scroll_percent : Float64
        @emulator.try(&.scroll_percent) || 0.0
      end

      # Terminates the child and tears down the PTY. Idempotent; safe to call
      # from `destroy`.
      def kill : Nil
        @pty.try &.kill
        @pty = nil
      end

      # Write-only `IO` delivering the emulator's solicited replies to the
      # external `handler`, in handler mode (no PTY).
      private class HandlerSink < IO
        def initialize(@handler : Proc(String, Nil))
        end

        def write(slice : Bytes) : Nil
          @handler.call(String.new(slice)) unless slice.empty?
        end

        def read(slice : Bytes) : Int32
          raise IO::Error.new("Crysterm::Widget::Terminal::HandlerSink is write-only")
        end
      end
    end
  end
end
