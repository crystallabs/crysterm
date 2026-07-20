module Crysterm
  # Text counterpart to `Capture`: serializes a region of the rendered cell
  # buffer into a deterministic, human-readable, diffable form — the exact
  # glyphs plus a run-length summary of non-default cell attributes.
  #
  # Enables golden testing without a comparison engine: commit a `.dump` next
  # to the example's `.png`/`.apng` and later changes show up as a localized
  # diff. The cell buffer is fully deterministic, so identical behavior
  # reproduces byte-for-byte identical text.
  module Dump
    # Serializes cells in the region `[xi,xl) x [yi,yl)` of *window*'s composited
    # buffer. Two sections:
    #
    #   * **text** — one line per row, each wrapped in `|...|` so trailing spaces
    #     and width changes are visible in a diff. Wide (2-column) graphemes emit
    #     their cluster once; their continuation cell is skipped.
    #   * **attrs** — for each row that has any non-default cell, a run-length
    #     list `col0-colN:fg/bg+flags` (columns relative to `xi`). Rows that are
    #     entirely the window default attribute are omitted, so a plain
    #     monochrome widget has an empty attrs section.
    def self.text(window : Window, xi : Int32, xl : Int32, yi : Int32, yl : Int32) : String
      w = xl - xi
      h = yl - yi
      String.build do |io|
        io << "w=" << w << " h=" << h << '\n'
        io << '+' << ("-" * w) << "+\n"

        rows = Array(String::Builder).new(h) { String::Builder.new }
        window.each_content_cell(xi, xl, yi, yl) do |cell, _rx, ry|
          g = cell.grapheme
          rows[ry] << (g.empty? ? " " : g)
        end
        rows.each { |rb| io << '|' << rb.to_s << "|\n" }
        io << '+' << ("-" * w) << "+\n"

        dfl = window.default_attr
        attr_lines = String.build do |a|
          (yi...yl).each do |y|
            line = window.lines[y]
            runs = String.build do |r|
              x = xi
              while x < xl
                attr = line[x].attr
                start = x
                x += 1
                while x < xl && line[x].attr == attr
                  x += 1
                end
                next if attr == dfl
                r << ' ' unless r.empty?
                r << (start - xi) << '-' << (x - 1 - xi) << ':' << attr_s(attr)
              end
            end
            next if runs.empty?
            a << 'y' << (y - yi) << ": " << runs << '\n'
          end
        end
        unless attr_lines.empty?
          io << "attrs:\n" << attr_lines
        end
      end
    end

    # `fg/bg` plus a `+flag` suffix for each set style flag, e.g. `#c0caf5/def+b`.
    def self.attr_s(attr : Int64) : String
      String.build do |io|
        io << color_s(Attr.fg(attr)) << '/' << color_s(Attr.bg(attr))
        flags = Attr.flags(attr)
        io << "+b" if flags & Attr::BOLD != 0
        io << "+u" if flags & Attr::UNDERLINE != 0
        io << "+k" if flags & Attr::BLINK != 0
        io << "+r" if flags & Attr::REVERSE != 0
        io << "+x" if flags & Attr::INVISIBLE != 0
        io << "+i" if flags & Attr::ITALIC != 0
        io << "+s" if flags & Attr::STRIKE != 0
      end
    end

    # `def` for the terminal default, else `#rrggbb`.
    private def self.color_s(field : Int64) : String
      c = Attr.unpack_color(field)
      c < 0 ? "def" : ("#%06x" % c)
    end
  end

  class Window
    # Normalizes a capture/dump region to the screen: floors the origin at 0,
    # caps the far edge at the screen size, and collapses an inverted region
    # (far edge before origin) to empty. Keeps a negative width/height from
    # reaching `Dump.text`, which would raise an opaque `ArgumentError` instead
    # of yielding an empty dump.
    private def clamp_capture_region(xi, xl, yi, yl) : {Int32, Int32, Int32, Int32}
      xi = xi.to_i; xl = xl.to_i; yi = yi.to_i; yl = yl.to_i
      xi = 0 if xi < 0
      yi = 0 if yi < 0
      xl = awidth if xl > awidth
      yl = aheight if yl > aheight
      xl = xi if xl < xi
      yl = yi if yl < yi
      {xi, xl, yi, yl}
    end

    # Entry point for capturing rendered screen content as an image or video.
    # Captures what the terminal shows — the flushed cell buffer rendered with a
    # bitmap font, plus in-band terminal-graphics backends (sixel/kitty/iterm/regis)
    # composited on top; external-helper and separate-window backends are excluded.
    #
    # Options:
    # * region — `xi`/`xl`/`yi`/`yl` in cells (whole screen by default).
    # * `format` — output format ("png", "mp4", "gif", "apng", "webm", "jpg", …).
    #   Defaults to the extension of `path`, or `"png"`.
    # * `path` — write the result to this file; if nil, the encoded bytes are
    #   returned instead.
    # * `duration` — when set, record an **animation** of this length (the screen
    #   keeps rendering meanwhile, so live interaction is captured); when nil, a
    #   single still frame is captured.
    # * `fps` — animation frame rate. `loops` — gif/apng loop count (0 = forever).
    # * `ffmpeg_args` — extra ffmpeg flags appended verbatim.
    #
    # Still PNG is encoded in-process (no external tools). Every other format,
    # and any animation, is encoded by piping raw RGBA frames to `ffmpeg` — only
    # required when asking for something other than a still PNG.
    #
    # Returns the encoded bytes when `path` is nil, otherwise `nil` (the output
    # is on disk). For a duration capture, call it from a fiber other than the one
    # running `Window#exec`, so the UI keeps rendering while it records.
    #
    # ```
    # screen.capture path: "shot.png" # still PNG, in-process
    # gif = screen.capture format: "gif", duration: 3.seconds, fps: 15
    # spawn { screen.capture path: "demo.mp4", duration: 10.seconds }
    # ```
    def capture(xi = 0, xl = awidth, yi = 0, yl = aheight, *,
                path : String? = nil,
                format : String? = nil,
                duration : Time::Span? = nil,
                fps : Int32 = 10,
                loops : Int32 = 0,
                font : BitmapFont = BitmapFont.default_normal,
                bold_font : BitmapFont = BitmapFont.default_bold,
                default_fg : Int32 = Capture::DEFAULT_FG,
                default_bg : Int32 = Capture::DEFAULT_BG,
                ffmpeg_args : Array(String)? = nil) : Bytes?
      xi, xl, yi, yl = clamp_capture_region xi, xl, yi, yl

      # Clamp the frame rate to at least 1 before it reaches the FrameClock /
      # ffmpeg args. `fps == 0` builds `Infinity.seconds`, which raises
      # `OverflowError`; a negative `fps` makes the clock interval negative so
      # `FrameClock#start` never sleeps (busy-spins at 100% CPU).
      fps = 1 if fps < 1

      # An inverted or fully out-of-range region clamps to empty — reachable
      # from `Widget#capture` with `include_decorations: false` on a widget
      # narrower than its own insets, or a large negative `d*` delta. There is
      # no image to produce, and `Capture.render` would raise an opaque
      # `ArgumentError("empty region")`.
      return nil if xl <= xi || yl <= yi

      fmt = (format || (path ? File.extname(path).lchop('.') : nil)).to_s.downcase
      fmt = "png" if fmt.empty?

      if duration
        capture_animation(xi, xl, yi, yl, fmt, path, duration, fps, loops,
          font, bold_font, default_fg, default_bg, ffmpeg_args)
      elsif fmt == "png"
        # In-process, no ffmpeg.
        data = Capture.png(self, xi, xl, yi, yl, font, bold_font, default_fg, default_bg)
        if path
          File.write(path, data)
          nil
        else
          data
        end
      else
        # Non-PNG: one frame through ffmpeg.
        bmp = Capture.render(self, xi, xl, yi, yl, font, bold_font, default_fg, default_bg)
        vw = bmp[0]?.try(&.size) || 0
        vh = bmp.size
        run_ffmpeg(vw, vh, 1, fmt, path, loops, ffmpeg_args) do |input|
          input.write Capture.rgba(bmp)
        end
      end
    end

    # Records the region for *duration*, sampling the current cell buffer on a
    # fixed `1/fps` wall-clock grid, piping raw RGBA to ffmpeg.
    private def capture_animation(xi, xl, yi, yl, fmt, path, duration, fps, loops,
                                  font, bold_font, default_fg, default_bg, ffmpeg_args) : Bytes?
      first = Capture.render(self, xi, xl, yi, yl, font, bold_font, default_fg, default_bg)
      vw = first[0]?.try(&.size) || 0
      vh = first.size

      run_ffmpeg(vw, vh, fps, fmt, path, loops, ffmpeg_args) do |input|
        feed_animation_frames(input, xi, xl, yi, yl, duration, fps,
          font, bold_font, default_fg, default_bg)
      end
    end

    # :nodoc:
    # Feeds an animation's raw RGBA frames to *input*: one frame immediately,
    # then one per `1/fps` tick of a `FrameClock` until *duration* elapses, so
    # the clip's timeline tracks the wall clock. An unchanged screen duplicates
    # frames; a slow tick drops them (the clock resyncs rather than bursting).
    # All writes are serialized: the initial frame completes on this fiber
    # before the clock fiber starts. Public (`:nodoc:`) so the sampling cadence
    # is testable without ffmpeg.
    def feed_animation_frames(input : IO, xi, xl, yi, yl, duration : Time::Span, fps : Int32,
                              font : BitmapFont = BitmapFont.default_normal,
                              bold_font : BitmapFont = BitmapFont.default_bold,
                              default_fg : Int32 = Capture::DEFAULT_FG,
                              default_bg : Int32 = Capture::DEFAULT_BG) : Nil
      # Floor the rate here too: a directly-reached public entry point must not
      # build an `Infinity`/negative clock interval from a non-positive `fps`.
      fps = 1 if fps < 1
      first = Capture.render(self, xi, xl, yi, yl, font, bold_font, default_fg, default_bg)
      input.write Capture.rgba(first) rescue nil
      # `FrameClock` invokes the tick block immediately on start, before its
      # first sleep — but the t=0 frame was already written above (on this
      # fiber, for write serialization), so the immediate tick is skipped to
      # keep the documented one-frame-per-1/fps cadence: including it would
      # duplicate frame 0 and stretch the clip by one frame period. Skipping
      # doesn't disturb the clock's phase-lock (`next_at` is computed from the
      # start time regardless).
      first_tick = true
      clock = FrameClock.new((1.0 / fps).seconds) do
        if first_tick
          first_tick = false
          next
        end
        begin
          bmp = Capture.render(self, xi, xl, yi, yl, font, bold_font, default_fg, default_bg)
          input.write Capture.rgba(bmp)
        rescue
          # Pipe closed / encoder gone: stop feeding it.
        end
      end
      clock.start
      sleep duration
      clock.stop
    end

    # Spawns ffmpeg for the given output, yields its stdin for frame writing, then
    # finalizes: closes stdin, collects stdout bytes (when no *path*), and reaps
    # the process. Returns the encoded bytes (no path) or nil (wrote to path).
    private def run_ffmpeg(vw, vh, fps, fmt, path, loops, ffmpeg_args, &) : Bytes?
      raise "Crysterm capture: empty frame (#{vw}x#{vh})" if vw <= 0 || vh <= 0
      args = Capture.ffmpeg_args(vw, vh, fps, fmt, path, loops, ffmpeg_args)
      devnull = File.open(File::NULL, "w")
      proc =
        begin
          Process.new("ffmpeg", args,
            input: Process::Redirect::Pipe,
            output: path ? devnull : Process::Redirect::Pipe,
            error: devnull)
        rescue ex
          devnull.close
          raise "Crysterm capture: ffmpeg required for format #{fmt.inspect} (#{ex.message})"
        end

      # Drain stdout concurrently (when capturing bytes) so a full pipe can't
      # deadlock against our frame writes.
      out_ch = nil
      if path.nil?
        out_ch = Channel(Bytes).new
        spawn { out_ch.try &.send(proc.output.getb_to_end) }
      end

      result = nil
      begin
        yield proc.input
      ensure
        # Reap the process and close fds even if the frame-writing block raised,
        # else an exception leaves a zombie ffmpeg and an open `/dev/null` fd.
        # Closing stdin first sends EOF so ffmpeg exits and the drain completes.
        proc.input.close rescue nil
        result = out_ch.try &.receive
        proc.wait
        devnull.close
      end
      result
    end

    # Walks the composited buffer over region `[xi,xl) x [yi,yl)`, yielding each
    # visible cell with its region-relative column/row. Out-of-range rows/cells
    # are skipped, as is the trailing continuation half of a wide (2-column)
    # grapheme — the lead cell carries the whole cluster. The one place the
    # "which cells are content" rule lives, so no two consumers can disagree
    # about wide glyphs or bounds.
    def each_content_cell(xi : Int32, xl : Int32, yi : Int32, yl : Int32,
                          & : Window::Cell, Int32, Int32 ->) : Nil
      (yi...yl).each do |y|
        line = lines[y]?
        next unless line
        (xi...xl).each do |x|
          cell = line[x]?
          next unless cell
          next if cell.continuation?
          yield cell, x - xi, y - yi
        end
      end
    end

    # Text counterpart to `Window#capture` — same region semantics, plain-text
    # output, via `Dump`. Renders nothing itself: call `_render` first so the
    # buffer reflects the intended frame.
    #
    # With *path*, writes the dump there and returns `nil`; otherwise returns the
    # dump as a `String`.
    #
    # ```
    # text = screen.dump             # -> String
    # screen.dump path: "frame.dump" # writes the file
    # ```
    def dump(xi = 0, xl = awidth, yi = 0, yl = aheight, *, path : String? = nil) : String?
      xi, xl, yi, yl = clamp_capture_region xi, xl, yi, yl

      text = Dump.text(self, xi, xl, yi, yl)
      if path
        File.write(path, text)
        nil
      else
        text
      end
    end

    # Whether any declarative CSS `transition` is currently tweening on any
    # widget in the tree. Lets a capture/test harness wait for a state change to
    # settle before snapshotting, so the recorded frame is deterministic rather
    # than a wall-clock-dependent mid-tween. Infinite `@keyframes` animations
    # have no settled state and are not counted here.
    def animating? : Bool
      # Local pre-order recursion rather than `each_descendant`, which yields
      # every node and so keeps scanning past the answer. `Array#any?` inlines
      # its block (no per-node `Proc`), so the walk stays allocation-free.
      children.any? { |c| descendant_transition_running? c }
    end

    # Whether *w* or any of its descendants has a `transition` currently tweening,
    # returning `true` as soon as one is found (early-exit helper for `#animating?`).
    private def descendant_transition_running?(w : Widget) : Bool
      return true if w.transition_running?
      w.children.any? { |c| descendant_transition_running? c }
    end
  end
end
