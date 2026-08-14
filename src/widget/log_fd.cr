require "./log"
require "../terminal/emulator"
require "../mixin/emulator_blit"

module Crysterm
  class Widget
    # Streams a file descriptor / `IO` — or a spawned subprocess's output — into a
    # scrolling text box. This is crysterm's answer to notcurses' `ncfdplane`
    # (the `IO` form) and `ncsubproc` (the command form).
    #
    # Two rendering modes, chosen with `mode:`:
    #
    # * `:text` (default, the true `ncfdplane`) — raw UTF-8 lines are appended and
    #   autoscrolled (via the `Log` base). Nothing here parses escapes: the lines
    #   are ordinary widget content, so crysterm's own renderer honours inline SGR
    #   colour/style runs, but everything else — cursor addressing, erases, scroll
    #   regions — lands as literal text (`\e[2J` shows up as `[2J`) and a program
    #   that repaints in place produces a transcript of its repaints.
    # * `:ansi` (the `ncsubproc`-with-control case) — bytes are fed to an embedded
    #   `TerminalEmulator` sized to the widget's content area, and its cell grid
    #   (colours, attributes, cursor addressing) is painted over the widget. This
    #   is `Widget::Terminal`'s emulator without the PTY: no keyboard/mouse/paste
    #   is forwarded, and the stream is one-way (solicited DSR/DA replies are
    #   discarded — there is no child input channel to answer on).
    #
    # For an *interactive* program (vim, htop, a shell) use `Widget::Terminal`
    # instead; LogFd is the "just tail this fd into a box" primitive.
    #
    # ```
    # # Tail an existing IO (a pipe, socket, opened file, ...):
    # LogFd.new io: some_io, parent: window
    #
    # # Or spawn a command and stream its stdout+stderr (the `ncsubproc` case):
    # LogFd.new "journalctl", ["-f"], parent: window
    #
    # # Control-aware: run the escape sequences instead of printing them.
    # LogFd.new "make", ["-j4"], mode: :ansi, parent: window
    # ```
    #
    # Reading begins once the widget is attached to a window (`Event::Attached`), so
    # appended lines can be marshalled onto the render fiber. You can also drive it
    # yourself, headless, by calling `#feed` with bytes/strings.
    #
    # Scrollback differs per mode: `:text` keeps `Log`'s line buffer (`max_lines`)
    # and the widget's own scrolling, while `:ansi` uses the emulator's scrollback
    # (`TerminalEmulator::SCROLLBACK_LIMIT` lines of scrolled-off *rows*) — the
    # widget itself is not scrollable there, and `#scroll`/`#scroll_to`/
    # `#reset_scroll`/`#scroll_percent` delegate to the emulator. The live view is
    # always the emulator's tail, matching `ncfdplane` semantics: a program that
    # repaints in place (a progress bar, `\e[2J`) shows its current state, not a
    # transcript.
    # Excluded from the DOM-loader registry: no window-only constructor (needs a live IO/command)
    # (see `Crysterm::DOM::Skip`).
    @[::Crysterm::DOM::Skip]
    class LogFd < Log
      include Mixin::EmulatorBlit

      # How incoming bytes are interpreted; see the class docs.
      enum Mode
        # Append raw UTF-8 lines; no sequence is executed (see the class docs).
        Text
        # Feed an embedded `TerminalEmulator` and paint its cell grid.
        Ansi
      end

      # The interpretation of the incoming byte stream. Fixed at construction:
      # switching mid-stream would leave one of the two backing stores (line
      # buffer / emulator grid) holding a half-consumed stream.
      getter mode : Mode

      # The embedded emulator in `:ansi` mode. `nil` in `:text` mode, and until
      # the first render in `:ansi` mode (it needs the resolved content size).
      getter emulator : TerminalEmulator? = nil

      # The spawned child, when constructed from a command (the `ncsubproc` case);
      # `nil` when wrapping a caller-supplied `IO`. Signalling/reaping go through
      # this object.
      getter process : Process?

      getter? closed = false

      # A partial trailing line (and/or an incomplete final read) carried across
      # `#feed` calls so a line split at a chunk boundary isn't emitted early.
      # UTF-8 glyphs are never split by newline-based chunking — a continuation
      # byte (`0x80`–`0xBF`) can never equal `'\n'` (`0x0A`) — so splitting on the
      # newline byte never corrupts a multibyte character.
      @carry : Bytes = Bytes.new(0)

      @io : IO?
      @started = false

      # A single logical line is flushed unconditionally once its buffered bytes
      # exceed this, so a firehose that never emits a newline can't grow `@carry`
      # (and its per-chunk recopy) without bound.
      MAX_LINE_BYTES = 1 << 20

      # `:ansi` bytes arriving before the emulator exists (see `#feed`) are held
      # here; capped so a widget that never renders can't grow it unboundedly.
      @pending : IO::Memory? = nil

      # Upper bound for `@pending`.
      PENDING_BYTES_CAP = 4 * 1024 * 1024

      # Wrap an existing readable `IO` (a pipe, socket, file, ...). The `IO` is
      # read on a background fiber once the widget is attached; on EOF the fiber
      # stops. The caller owns the `IO`'s lifetime beyond `#close`.
      def initialize(io : IO, mode : Mode = Mode::Text, **log)
        @mode = mode
        super **log
        @io = io
        wire
      end

      # Spawn *command* (with *args*) and stream its stdout **and** stderr into the
      # plane, merged into one pipe so diagnostics interleave with output like a
      # real terminal tail. stdin is closed.
      #
      # The child is spawned immediately (so a bad command raises here, not later)
      # but only drained once the widget is attached. `#close` / destroy terminate
      # and reap it.
      def initialize(command : String, args : Array(String) = [] of String,
                     env : Process::Env = nil, chdir : String? = nil,
                     mode : Mode = Mode::Text, **log)
        @mode = mode
        super **log

        # One pipe fed by both stdout and stderr: the parent reads a single
        # stream, and closing our copy of the write end lets the reader see EOF
        # when the child exits. `IO.pipe` defaults to a non-blocking read end, so
        # the reader fiber yields through the event loop instead of parking the
        # thread and starving keyboard input.
        reader, writer = IO.pipe
        process = begin
          Process.new(command, args, env: env, chdir: chdir,
            input: Process::Redirect::Close, output: writer, error: writer)
        rescue ex
          reader.close rescue nil
          writer.close rescue nil
          raise ex
        end
        writer.close # the child holds its own dup'd copy

        @process = process
        @io = reader
        wire
      end

      private def wire : Nil
        # In `:ansi` mode the emulator owns the grid *and* the scrollback: no
        # content lines are ever appended, so the widget's own text scrolling has
        # nothing to scroll (and would fight the emulator's viewport). Same
        # arrangement as `Widget::Terminal`.
        @scrollable = false if @mode.ansi?

        on(::Crysterm::Event::Attached) { start }
        on(::Crysterm::Event::Destroy) { close }
        # A `parent:`/`window:` passed to the constructor already fired
        # `Event::Attached` during `super`, before the handler above existed, so
        # kick the reader off now if we're already attached. Later re-attaches go
        # through the handler (a no-op once `@started`).
        start if window?
      end

      # Splits *carry* + *chunk* on the newline byte into complete lines,
      # stripping a trailing `\r` (CRLF streams), and returns the extracted
      # lines plus the leftover partial line to carry into the next call. The
      # generic implementation lives in the crystallabs-helpers shard; kept as
      # a named entry point because it is this widget's documented API.
      def self.extract_lines(carry : Bytes, chunk : Bytes) : {Array(String), Bytes}
        Crystallabs::Helpers::Streams.extract_lines carry, chunk
      end

      # Feed a raw chunk (bytes or string) into the plane. In `:text` mode it is
      # split into complete lines, each appended, with any trailing partial line
      # carried to the next call; in `:ansi` mode it goes to the emulator
      # verbatim (which does its own UTF-8 carry across chunks).
      # Public so you can drive the widget from your own source.
      def feed(data : Bytes | String) : Nil
        slice = data.is_a?(String) ? data.to_slice : data
        return feed_ansi slice if @mode.ansi?
        lines, @carry = LogFd.extract_lines(@carry, slice)
        lines.each { |l| add l }
        # A single line that never terminates must not grow the carry forever.
        flush_carry if @carry.size > MAX_LINE_BYTES
      end

      # `:ansi` mode: bytes go straight into the emulator. Before the first
      # render there is no emulator yet (it is sized from the resolved content
      # area), so the stream's prefix is buffered and replayed at bootstrap —
      # dropping it would desync the grid for the rest of the stream (same
      # reasoning as `Widget::Terminal#write`). Overflow drops the tail, keeping
      # the prefix that seeds the screen state.
      private def feed_ansi(slice : Bytes) : Nil
        if em = @emulator
          em.feed slice
        elsif (pending = @pending ||= IO::Memory.new).size + slice.size <= PENDING_BYTES_CAP
          pending.write slice
        end
        update!
      end

      # Emit any buffered partial line as a final line (used on EOF and the
      # runaway-line cap). No-op when the carry is empty — which it always is in
      # `:ansi` mode, where nothing is line-buffered.
      def flush_carry : Nil
        return if @carry.empty?
        add String.new(@carry)
        @carry = Bytes.new(0)
      end

      # Starts the background reader. Idempotent (`Event::Attached` can re-fire on
      # re-attach) and a no-op once closed.
      private def start : Nil
        return if @started || @closed
        io = @io
        return unless io
        @started = true

        # A fresh buffer per read so the slice captured by the posted closure is
        # never overwritten by the next read before the render fiber consumes it.
        spawn do
          loop do
            buf = Bytes.new 8192
            n = io.read buf
            break if n <= 0
            data = buf[0, n]
            window?.try &.post { feed data }
          rescue
            break
          end
          window?.try &.post { flush_carry }
          reap
        end
      end

      # Reaps the child (if any) after EOF and surfaces its exit status. Runs on
      # the reader fiber, so `Process#wait` yields rather than blocking the loop.
      private def reap : Nil
        if p = @process
          code = p.wait.exit_code rescue nil
          emit ::Crysterm::Event::ProcessExited, code
        end
      end

      # ── `:ansi` mode: emulator sizing, painting and scrollback ──

      # Inner content width/height in cells (box minus border+padding), i.e. the
      # emulator's window size.
      private def content_cols : Int32
        Math.max(0, awidth - ihorizontal)
      end

      private def content_rows : Int32
        Math.max(0, aheight - ivertical)
      end

      # Renders via the base implementation (box, border, background), then — in
      # `:ansi` mode — sizes the emulator to the content area and paints its grid
      # over it. `:text` mode is left entirely to `Log`/`ScrollableText`.
      def paint(with_children = true)
        coords = super
        return coords unless coords && @mode.ansi?

        cols = content_cols
        rows = content_rows
        if cols > 0 && rows > 0
          if em = @emulator
            # The widget was resized: re-size the emulator with it. Content is
            # kept at the top-left (the emulator does not reflow), and there is
            # no PTY to send a window-size change to.
            em.resize cols, rows if em.cols != cols || em.rows != rows
          else
            bootstrap_emulator cols, rows
          end
        end

        draw_ansi coords
        coords
      end

      # Builds the emulator at the first render with a positive content size and
      # replays whatever `#feed` buffered before it existed. No `output` sink is
      # wired: an fd/subprocess stream is one-way, so solicited replies (DSR/DA)
      # have nowhere to go and are discarded.
      private def bootstrap_emulator(cols : Int32, rows : Int32) : Nil
        em = TerminalEmulator.new cols, rows, style_to_attr(style)
        em.on_refresh = -> { update!; nil }
        @emulator = em

        if pending = @pending
          @pending = nil
          em.feed pending.to_slice unless pending.empty?
        end
      end

      # Copies the emulator grid onto the window cells covering our content area,
      # via the blit shared with `Widget::Terminal` (`Mixin::EmulatorBlit`) — but
      # with no cursor overlay: nothing here is focusable input.
      private def draw_ansi(coords) : Nil
        em = @emulator
        return unless em

        # Keep the emulator's "default" attr in sync with the live style, so
        # default-coloured cells track theme changes.
        em.default_attr = style_to_attr style

        blit_emulator_grid em, coords
      end

      # Scrollback controls. In `:ansi` mode the emulator owns the history, so
      # these delegate to it (the widget holds no content lines); in `:text` mode
      # they are the inherited `Widget` text scrolling, untouched.
      def scroll(offset = 1, always = false)
        if em = @emulator
          em.scroll offset.to_i
          emit Crysterm::Event::Scroll, offset
          update!
        else
          super
        end
      end

      # :ditto:
      def scroll_to(offset, always = false)
        if em = @emulator
          em.scroll_to offset.to_i
          emit Crysterm::Event::Scroll
          update!
        else
          super
        end
      end

      # :ditto:
      def reset_scroll
        if em = @emulator
          em.reset_scroll
          emit Crysterm::Event::Scroll
          update!
        else
          super
        end
      end

      # :ditto:
      def scroll_percent : Float64
        if em = @emulator
          em.scroll_percent
        else
          super
        end
      end

      # Stops streaming: closes our read end (unblocking the reader → EOF path)
      # and terminates the child. Idempotent; wired to `Event::Destroy`.
      def close : Nil
        return if @closed
        @closed = true
        @process.try { |p| p.terminate rescue nil }
        @io.try &.close rescue nil
        # If the reader never started, nothing else will reap the child.
        unless @started
          @process.try { |p| p.wait rescue nil }
        end
      end
    end
  end
end
