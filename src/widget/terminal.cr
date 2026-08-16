require "../terminal/pty"
require "../terminal/emulator"
require "../mixin/emulator_blit"

module Crysterm
  class Widget
    # A terminal-emulator widget: runs a child program (a shell by default)
    # inside a pseudo-terminal and renders its output as a live, scrollable
    # window.
    #
    # `Crysterm::Pty` spawns and talks to the child via a PTY, and
    # `Crysterm::TerminalEmulator` parses its byte stream into a cell grid. This
    # widget wires them to the window: sizes them from its inner area, forwards
    # keystrokes, copies the emulator grid onto `window.cell_rows` each render, and
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
      include Mixin::EmulatorBlit

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

        on ::Crysterm::Event::KeyPress, ->handle_key_press(::Crysterm::Event::KeyPress)
        on ::Crysterm::Event::Mouse, ->handle_mouse(::Crysterm::Event::Mouse)
        on ::Crysterm::Event::Paste, ->handle_paste(::Crysterm::Event::Paste)
        on(::Crysterm::Event::FocusIn) { report_focus true }
        on(::Crysterm::Event::FocusOut) { report_focus false }
        on(::Crysterm::Event::Destroy) { kill }
      end

      # Installs the raw-input `handler` (the block form of the `handler:` ctor
      # param) via a block: `term.input_handler { |bytes| ... }`.
      #
      # CONSTRAINT: must be called *before the widget bootstraps* (its first
      # render). `@handler` is consumed in `#bootstrap`, which decides there and
      # then whether to spawn a PTY (no handler) or run externally-driven (with
      # one); once bootstrapped the choice is fixed, so a later install would be
      # silently ignored. Raises if the widget has already bootstrapped.
      def input_handler(&block : String ->) : Nil
        raise "Widget::Terminal#input_handler must be set before the terminal bootstraps (first render)" if @bootstrapped
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
        update!
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
        em.on_refresh = -> { update!; nil }
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
      protected def handle_key_press(e : ::Crysterm::Event::KeyPress) : Nil
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
          when "\e[5;2~" then scroll(-page); e.accept; update!; return
          when "\e[6;2~" then scroll(page); e.accept; update!; return
          end
          # Any real keystroke snaps the view back to the live bottom (xterm UX).
          em.reset_scroll if em.ydisp != em.ybase
        end

        return unless forward_to_child data

        e.accept
        update!
      end

      # Forwards pasted text (routed here by the window while focused) to the
      # child, wrapped in bracketed-paste markers when the child has enabled
      # the mode (DECSET 2004) — so a child readline/editor can treat the
      # paste atomically instead of as typed input.
      protected def handle_paste(e : ::Crysterm::Event::Paste) : Nil
        return unless focused?

        data = e.content
        if @emulator.try &.bracketed_paste?
          data = "\e[200~#{data}\e[201~"
        end

        return unless forward_to_child data

        # Like a keystroke, input snaps the view back to the live bottom.
        @emulator.try { |em| em.reset_scroll if em.ydisp != em.ybase }
        e.accept
        update!
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
      def handle_mouse(e : ::Crysterm::Event::Mouse) : Nil
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
        # position before the first render (direct `handle_mouse` calls have no
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
        update!
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
      # The wire encoder itself is `Tput::Mouse.encode` — the generation-side
      # twin of tput's report parsers, kept with them so the two directions of
      # one wire format can't drift; this method only maps the emulator's
      # DECSET-tracked encoding onto tput's and reuses the scratch buffer.
      private def encode_mouse(em : TerminalEmulator, e : ::Crysterm::Event::Mouse, col : Int32, row : Int32) : Bytes
        encoding = case em.mouse_encoding
                   in .sgr?    then ::Tput::Mouse::Encoding::Sgr
                   in .urxvt?  then ::Tput::Mouse::Encoding::Urxvt
                   in .utf8?   then ::Tput::Mouse::Encoding::Utf8
                   in .normal? then ::Tput::Mouse::Encoding::Normal
                   end
        io = @mouse_buf
        io.clear
        ::Tput::Mouse.encode(io, encoding, e.action, e.button, col + 1, row + 1,
          shift: e.shift?, meta: e.meta?, ctrl: e.ctrl?)
        io.to_slice
      end

      # Sends input to the child (PTY, or the external handler as a String).
      # Returns `false` when there is no sink at all, so callers that must not
      # consume the event (`e.accept`/`update!`) when the data went
      # nowhere can bail out; callers that don't care ignore the result.
      private def forward_to_child(data : Bytes | String) : Bool
        if handler = @handler
          handler.call(data.is_a?(String) ? data : String.new(data))
        elsif pty = @pty
          pty.write data
        else
          return false
        end
        true
      end

      # Renders via the base implementation, then overlays the emulator grid and
      # cursor onto the inner area.
      def paint(*, with_children = true)
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

      # Syncs the emulator's default attr to the live style, then blits the
      # grid via `Mixin::EmulatorBlit`, overlaying the cursor when visible.
      private def draw(coords) : Nil
        em = @emulator
        return unless em

        # Keep the emulator's "default" attr in sync with the live style so
        # default-coloured cells track theme changes.
        @dattr = style_to_attr style
        em.default_attr = @dattr

        # Cursor position in window coordinates, mapped exactly like the blit
        # maps grid cells: rows through `coords.base`, columns through the
        # unclipped content origin (see `Mixin::EmulatorBlit`).
        xi, xl, yi, yl = content_edges coords
        cur_y = yi + em.cursor_y - coords.base
        cur_x = aleft + ileft + em.cursor_x
        # The cursor is hidden while the user is scrolled back into history, and
        # skipped when it maps outside the (possibly clipped) visible viewport.
        show_cursor = window.focused == self && !em.cursor_hidden? && em.ydisp == em.ybase &&
                      cur_y >= Math.max(yi, 0) && cur_y < yl &&
                      cur_x >= Math.max(xi, 0) && cur_x < xl

        if show_cursor
          blit_emulator_grid(em, coords, cur_x, cur_y) { |attr, ch| apply_cursor attr, ch }
        else
          blit_emulator_grid em, coords
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
          # Invert the cell. Toggle (not OR) REVERSE, matching the same toggle in
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
