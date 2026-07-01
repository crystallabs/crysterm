require "../widget_terminal_pty"
require "../widget_terminal_emulator"

module Crysterm
  class Widget
    # A terminal-emulator widget: runs a child program (a shell by default)
    # inside a pseudo-terminal and renders its output as a live, scrollable
    # window.
    #
    # Split into two self-contained helpers: `Crysterm::Pty` spawns and talks
    # to the child via a PTY, `Crysterm::TerminalEmulator` parses its byte
    # stream into a cell grid. This widget wires them to the window: sizes them
    # from its inner area, forwards keystrokes, copies the emulator grid onto
    # `window.lines` each render, and draws the cursor.
    #
    # Usage:
    # ```
    # term = Crysterm::Widget::Terminal.new width: 80, height: 24
    # window.append term
    # term.focus
    # ```
    #
    # Keyboard and mouse are both forwarded to the child; the emulator supports
    # the alternate window buffer, DEC line-drawing, scroll regions/scrollback,
    # origin mode, and focus reporting. Scrollback is navigable with
    # Shift-PageUp/PageDown, and `Event::Exit` fires (with the exit code) when the
    # child process ends. Not yet implemented: double-width/height *lines* and
    # bracketed-paste wrapping (the mode is tracked but Crysterm has no paste
    # event to wrap yet).
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

      # Cursor shape drawn over the emulator's cursor cell: `:block` (default),
      # `:underline`, or `:line`.
      property cursor_shape : Symbol

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

      def initialize(
        *,
        shell : String? = nil,
        args : Array(String) = [] of String,
        cursor_shape : Symbol = :block,
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

        on ::Crysterm::Event::KeyPress, ->on_data(::Crysterm::Event::KeyPress)
        on ::Crysterm::Event::Mouse, ->on_mouse(::Crysterm::Event::Mouse)
        on(::Crysterm::Event::Focus) { report_focus true }
        on(::Crysterm::Event::Blur) { report_focus false }
        on(::Crysterm::Event::Destroy) { kill }
      end

      # Feeds output bytes into the emulator directly. Useful with a `handler`
      # (no PTY) to drive the display from an arbitrary source.
      def write(data : Bytes | String) : Nil
        @emulator.try &.feed(data.is_a?(String) ? data.to_slice : data)
        request_render
      end

      # Inner content width/height in cells (box minus border+padding).
      private def term_cols : Int32
        Math.max(0, awidth - iwidth)
      end

      private def term_rows : Int32
        Math.max(0, aheight - iheight)
      end

      private def bootstrap(cols : Int32, rows : Int32) : Nil
        return if @bootstrapped
        @bootstrapped = true

        @dattr = sattr style
        em = TerminalEmulator.new cols, rows, @dattr
        em.on_refresh = -> { request_render; nil }
        em.on_title = ->(t : String) { @title = t; emit ::Crysterm::Event::SetContent; nil }
        @emulator = em

        if handler = @handler
          # Externally driven: nothing to spawn. Keystrokes go to the handler
          # (see #on_data); output arrives via #write. The emulator's solicited
          # replies (DSR cursor-position, DA device-attributes) are child-bound
          # too, so route them to the handler as well — otherwise `em.output`
          # stays nil and a child probing the terminal at startup (vim/htop
          # query DA/CPR) waits forever. PTY path wires this to `pty.master` below.
          em.output = HandlerSink.new handler
          return
        end

        pty = Pty.new @shell, @args, cols, rows, @env
        @pty = pty
        em.output = pty.master # so DSR/DA replies reach the child

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
          emit ::Crysterm::Event::Exit, code
          emit ::Crysterm::Event::Destroy
        end
      end

      # Forwards a keystroke to the child as raw bytes. `Event::KeyPress#sequence`
      # carries the original input bytes tput read, exactly what the child expects.
      def on_data(e : ::Crysterm::Event::KeyPress) : Nil
        return unless focused?

        data = e.sequence.join

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
        # Only forward what the child's active tracking mode asked for (see
        # `#mouse_event_wanted?`) — forwarding everything floods a child in
        # normal mode with unrequested motion reports.
        return unless mouse_event_wanted? em, e

        # Coordinates relative to the inner (content) area, 0-based.
        col = e.x - (aleft + ileft)
        row = e.y - (atop + itop)
        return if col < 0 || row < 0 || col >= term_cols || row >= term_rows

        # A click still focuses the terminal (default path suppressed below via accept).
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
        sgr = em.mouse_encoding == :sgr
        cb = mouse_cb e, sgr
        x1 = col + 1
        y1 = row + 1
        released = e.action.up?

        io = IO::Memory.new
        case em.mouse_encoding
        when :sgr
          io << "\e[<" << cb << ';' << x1 << ';' << y1 << (released ? 'm' : 'M')
        when :urxvt
          io << "\e[" << (cb + 32) << ';' << x1 << ';' << y1 << 'M'
        else # :normal / :utf8 (utf8 handled as normal, best-effort)
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
        @dattr = sattr style
        em.default_attr = @dattr

        lines = window.lines

        xi = coords.xi + ileft
        xl = coords.xl - iright
        yi = coords.yi + itop
        yl = coords.yl - ibottom

        disp = em.ydisp
        focused = window.focused == self
        # The cursor is hidden while the user is scrolled back into history.
        show_cursor = focused && !em.cursor_hidden? && disp == em.ybase
        cur_y = yi + em.cursor_y
        cur_x = xi + em.cursor_x
        full_unicode = window.full_unicode?

        y = Math.max yi, 0
        while y < yl
          line = lines[y]?
          break unless line
          src = em.lines[disp + (y - yi)]?
          break unless src

          cursor_col = (show_cursor && y == cur_y) ? cur_x : -1

          x = Math.max xi, 0
          while x < xl
            cell = line[x]?
            break unless cell
            scell = src[x - xi]?
            break unless scell

            attr = scell.attr
            ch = scell.char
            # The emulator parks a NUL in the trailing half of a wide glyph;
            # render as blank (in full-unicode mode the wide glyph below claims
            # the following cell as a real continuation, skipping this).
            ch = ' ' if ch == TerminalEmulator::CONTINUATION

            if x == cursor_col
              attr, ch = apply_cursor attr, ch
            end

            if cell != {attr, ch}
              cell.attr = attr
              cell.char = ch
              line.dirty = true
            end

            # Wide glyph: claim the following window cell as its continuation so
            # the window grid stays 1 cell == 1 terminal column. This holds even
            # when the cursor sits on the lead half (`x == cursor_col`): `attr`
            # already carries the cursor styling from `apply_cursor` above, so
            # we still consume both columns rather than emitting only one.
            if full_unicode && (nxt = line[x + 1]?) &&
               x + 1 < xl && ::Crysterm::Unicode.width(ch) == 2
              nxt_attr = attr
              # If the cursor sits on the TRAILING (continuation) half of this
              # wide glyph, this branch would otherwise swallow the cursor column
              # (`x += 2` skips it) leaving the cursor invisible. Carry the cursor
              # styling onto the continuation cell so it stays visible there.
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
        case @cursor_shape
        when :line
          # A bar/beam cursor overlays the column (the host terminal draws the
          # real beam there); it must not hide the cell's glyph or color, so
          # preserve both `ch` and `attr` rather than overwriting with '│'.
          {attr, ch}
        when :underline
          {Attr.pack(Attr.flags(attr) | Attr::UNDERLINE, Attr.fg(attr), Attr.bg(attr)), ch}
        else # :block — invert the cell
          {Attr.pack(Attr.flags(attr) | Attr::REVERSE, Attr.fg(attr), Attr.bg(attr)), ch}
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

      def scroll_percentage : Float64
        @emulator.try(&.scroll_perc) || 0.0
      end

      # Terminates the child and tears down the PTY. Idempotent; safe to call
      # from `destroy`.
      def kill : Nil
        @pty.try &.kill
        @pty = nil
      end

      # Write-only `IO` delivering the emulator's solicited replies to the
      # external `handler`. Used in handler mode (no PTY); PTY path uses
      # `pty.master` directly.
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
