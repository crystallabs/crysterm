module Crysterm
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
      return if xl <= xi || yl <= yi

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

    # :nodoc:
    # Feeds an animation's raw RGBA frames to *input*: one frame immediately,
    # then one per `1/fps` tick of a `FrameClock` until *duration* elapses, so
    # the clip's timeline tracks the wall clock. An unchanged screen duplicates
    # frames; a slow tick drops them (the clock resyncs rather than bursting).
    # All writes are serialized: the initial frame completes on this fiber
    # before the clock fiber starts. Public (`:nodoc:`) so the sampling cadence
    # is testable without ffmpeg.
    #
    # *first* is the already-rendered frame 0. `#capture_animation` has to render
    # the region anyway to learn the video's pixel dimensions, so it passes that
    # bitmap through instead of letting it be rendered a second time; reached
    # directly (without one) this renders its own.
    def feed_animation_frames(input : IO, xi, xl, yi, yl, duration : Time::Span, fps : Int32,
                              font : BitmapFont = BitmapFont.default_normal,
                              bold_font : BitmapFont = BitmapFont.default_bold,
                              default_fg : Int32 = Capture::DEFAULT_FG,
                              default_bg : Int32 = Capture::DEFAULT_BG,
                              first : PNGGIF::Bitmap? = nil) : Nil
      # Floor the rate here too: a directly-reached public entry point must not
      # build an `Infinity`/negative clock interval from a non-positive `fps`.
      fps = 1 if fps < 1
      first ||= Capture.render(self, xi, xl, yi, yl, font, bold_font, default_fg, default_bg)
      input.write Capture.rgba(first) rescue nil
      # `FrameClock` invokes the tick block immediately on start, before its
      # first sleep — but the t=0 frame was already written above (on this
      # fiber, for write serialization), so `immediate: false` moves the
      # clock's own first tick to t≈1/fps, keeping the documented
      # one-frame-per-1/fps cadence: an immediate tick here would duplicate
      # frame 0 and stretch the clip by one frame period. This doesn't disturb
      # the clock's phase-lock (`next_at` is computed from the start time
      # regardless).
      # Frames fed so far (frame 0 was written above). Drives the blink phase:
      # `Attr::BLINK` cells hide on alternate half-second phases, so blinking
      # text actually blinks in the clip (a still keeps it visible).
      frame = 1
      clock = FrameClock.new((1.0 / fps).seconds, immediate: false) do
        hidden = (frame * 2 // fps).odd?
        frame += 1
        bmp = Capture.render(self, xi, xl, yi, yl, font, bold_font, default_fg, default_bg,
          blink_hidden: hidden)
        input.write Capture.rgba(bmp)
      rescue
        # Pipe closed / encoder gone: stop feeding it.
      end
      clock.start
      sleep duration
      clock.stop
    end

    # The artificial cursor's contribution to the cell at (*x*, *y*), for the
    # capture/dump readers. `#draw` composites the artificial cursor into the
    # terminal byte stream only — never into `#lines`, where it would become
    # content and corrupt the next diff — so a capture reading the cell buffer
    # would silently omit it, despite "shows even in captures" being the
    # artificial cursor's signature ability. Returns the composited
    # `{attr, char}` (char `nil` = keep the cell's own glyph, as for the
    # block/underline shapes), or `nil` when no artificial cursor glyph is
    # currently painted at that position (per the last `#draw`).
    def capture_cursor_overlay(x : Int32, y : Int32) : {Int64, Char?}?
      return unless @_acur_y >= 0 && x == @_acur_x && y == @_acur_y
      c = active_cursor
      return unless c.artificial? && !c._hidden && c._state != 0
      attr = lines[y]?.try &.[x]?.try &.attr
      return unless attr
      _artificial_cursor_attr c, attr
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
    # output, via `Dump`. Renders nothing itself: call `repaint` first so the
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
