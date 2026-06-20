require "../pty"
require "../terminal_emulator"

module Crysterm
  class Widget
    # A terminal-emulator widget: runs a child program (a shell by default)
    # inside a pseudo-terminal and renders its output as a live, scrollable
    # screen — the Crystal counterpart of blessed's `terminal` element.
    #
    # The heavy lifting is split into two self-contained helpers that are
    # candidates for their own shards (see their files): `Crysterm::Pty` spawns
    # and talks to the child via a PTY, and `Crysterm::TerminalEmulator` parses
    # the child's byte stream into a cell grid. This widget wires them to the
    # screen: it sizes them from its inner area, forwards keystrokes to the
    # child, copies the emulator grid onto `screen.lines` each render, and draws
    # the cursor.
    #
    # Usage:
    # ```
    # term = Crysterm::Widget::Terminal.new width: 80, height: 24
    # screen.append term
    # term.focus
    # ```
    #
    # Differences from blessed (intentional, v1): mouse events are not yet
    # forwarded to the child (keyboard is); the alternate-screen buffer is not a
    # separate page. Both are localized and straightforward to add later.
    class Terminal < Widget
      # A terminal manages its own scrollback; it is not a scrollable Box.
      @scrollable = false

      # The running child process wrapper, or `nil` when an external `handler`
      # supplies the data instead of a spawned process.
      getter pty : Pty? = nil

      # The emulator holding the parsed screen grid. `nil` until the first render
      # (we need the resolved inner geometry to size it).
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
      # with raw input bytes (keystrokes) and the caller is responsible for
      # feeding output back via `#write`. Mirrors blessed's `handler` option
      # (used to drive a terminal from a remote socket, recording, etc.).
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
        @shell = shell || ENV["SHELL"]? || "sh"
        @args = args
        @cursor_shape = cursor_shape
        @term_name = term_name || ENV["TERM"]? || "xterm"
        @env = env
        @handler = handler

        super **box

        # The widget must receive keyboard input and participate in focus.
        @keys = true
        @input = true
        screen?.try &.register_keyable self

        on ::Crysterm::Event::KeyPress, ->on_data(::Crysterm::Event::KeyPress)
        on(::Crysterm::Event::Destroy) { kill }
      end

      # Feeds output bytes into the emulator directly. Useful with a `handler`
      # (no PTY) to drive the display from an arbitrary source.
      def write(data : Bytes | String) : Nil
        @emulator.try &.feed(data.is_a?(String) ? data.to_slice : data)
        screen?.try &.render
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
        em.on_refresh = -> { screen?.try(&.render); nil }
        em.on_title = ->(t : String) { @title = t; emit ::Crysterm::Event::SetContent; nil }
        @emulator = em

        if handler = @handler
          # Externally driven: nothing to spawn. Keystrokes go to the handler
          # (see #on_data); output arrives via #write.
          return
        end

        pty = Pty.new @shell, @args, cols, rows, @env
        @pty = pty
        em.output = pty.master # so DSR/DA replies reach the child

        # Reader fiber: pump child output into the emulator. Crystal fibers are
        # cooperatively scheduled on one thread, so feeding the emulator and the
        # render it triggers never race with the main loop.
        spawn do
          buf = Bytes.new 8192
          loop do
            n = pty.master.read buf
            break if n == 0
            em.feed buf[0, n]
          rescue
            break
          end
          emit ::Crysterm::Event::Destroy
        end
      end

      # Forwards a keystroke to the child as raw bytes. `Event::KeyPress#sequence`
      # carries the original input bytes tput read, which is exactly what the
      # child expects (arrow keys arrive as their escape sequences, etc.).
      def on_data(e : ::Crysterm::Event::KeyPress) : Nil
        return unless screen?.try { |s| s.focused == self }

        data = e.sequence.join

        if handler = @handler
          handler.call data
        elsif pty = @pty
          pty.write data
        else
          return
        end

        e.accept
        screen?.try &.render
      end

      # Renders the box (border/background/children) via the base implementation,
      # then overlays the emulator grid and cursor onto the inner area.
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

        # Keep the emulator's notion of "default" in sync with the live style so
        # default-coloured cells track theme/style changes.
        @dattr = sattr style
        em.default_attr = @dattr

        lines = screen.lines

        xi = coords.xi + ileft
        xl = coords.xl - iright
        yi = coords.yi + itop
        yl = coords.yl - ibottom

        disp = em.ydisp
        focused = screen.focused == self
        show_cursor = focused && !em.cursor_hidden? && disp == em.ybase
        cur_y = yi + em.cursor_y
        cur_x = xi + em.cursor_x

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

            if x == cursor_col
              attr, ch = apply_cursor attr, ch
            end

            if cell != {attr, ch}
              cell.attr = attr
              cell.char = ch
              line.dirty = true
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
          {@dattr, '│'}
        when :underline
          {Attr.pack(Attr.flags(attr) | Attr::UNDERLINE, Attr.fg(attr), Attr.bg(attr)), ch}
        else # :block — invert the cell
          {Attr.pack(Attr.flags(attr) | Attr::INVERSE, Attr.fg(attr), Attr.bg(attr)), ch}
        end
      end

      # ── scrollback controls (delegate to the emulator) ──

      def scroll_to(offset : Int32) : Nil
        @emulator.try &.scroll_to(offset)
        emit ::Crysterm::Event::Scroll
      end

      def scroll(offset : Int32) : Nil
        @emulator.try &.scroll(offset)
        emit ::Crysterm::Event::Scroll
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
    end
  end
end
