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
    # `Rectangle` overload of `#capture` (`rect` covers `[xi, xl) × [yi, yl)`).
    def capture(rect : Rectangle, **opts) : Bytes?
      capture rect.xi, rect.xl, rect.yi, rect.yl, **opts
    end

    def capture(xi : Number = 0, xl : Number = awidth, yi : Number = 0, yl : Number = aheight, *,
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
    # the clip's timeline tracks the wall clock. All writes are serialized: the
    # initial frame completes on this fiber before the clock fiber starts, and
    # every later write happens on the clock fiber. Public (`:nodoc:`) so the
    # sampling cadence is testable without ffmpeg.
    #
    # The strip has a **fixed length** — exactly `duration * fps` frames — and
    # each rendered frame is placed in the slot its own wall-clock instant falls
    # in, not simply appended. The encoder holds every frame for `1/fps`, so
    # frame *count* is what sets playback speed: sampling that ran slow (a heavy
    # scene rendering below `fps`, or a `FrameClock` that dropped catch-up
    # ticks) would otherwise emit fewer frames than the recording lasted and
    # play the whole clip back sped up — a 5 s recording replaying in 2.5 s —
    # while a late wake-up from the `sleep` below would stretch it. Slots the
    # sampler was too slow to reach are filled by repeating the last frame it
    # did produce (what the screen actually showed then), and the strip is
    # padded/stopped at `total` so real time and clip time stay 1:1. Repeats
    # cost almost nothing: the encoder diffs consecutive frames.
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
      # Frame 0 always exists, so a sub-frame-period duration yields a 1-frame
      # strip rather than an empty (unencodable) one.
      total = (duration.total_seconds * fps).round.to_i
      total = 1 if total < 1

      first ||= Capture.render(self, xi, xl, yi, yl, font, bold_font, default_fg, default_bg)
      last = Capture.rgba(first)
      input.write last rescue nil
      # Slots filled so far; frame 0 was written above, on this fiber, for write
      # serialization. `FrameClock` would otherwise invoke the tick block once
      # immediately on start (before its first sleep) and duplicate it, so
      # `immediate: false` moves the clock's own first tick to t≈1/fps. This
      # doesn't disturb the clock's phase-lock (`next_at` derives from the start
      # time regardless).
      written = 1
      start_at = Time.instant

      clock = FrameClock.ticker((1.0 / fps).seconds, immediate: false) do |clk|
        if written >= total
          clk.stop # strip complete; nothing left to sample
        else
          # The slot this instant belongs to, clamped to the strip's last one.
          slot = (FrameClock.elapsed_since(start_at) * fps).round.to_i
          slot = total - 1 if slot > total - 1
          # An early tick lands in an already-filled slot: skip it rather than
          # overwrite (or append past) the frame that owns that instant.
          if slot >= written
            (slot - written).times { input.write last }
            # Blink phase comes from the slot, not a tick counter: `Attr::BLINK`
            # cells hide on alternate half-second phases of the *clip's* clock,
            # so blinking text keeps blinking at the right rate even when
            # sampling stumbled (a still keeps it visible).
            hidden = (slot * 2 // fps).odd?
            bmp = Capture.render(self, xi, xl, yi, yl, font, bold_font, default_fg, default_bg,
              blink_hidden: hidden)
            last = Capture.rgba(bmp)
            input.write last
            written = slot + 1
          end
        end
      rescue
        # Pipe closed / encoder gone: stop feeding it.
      end

      # Top the strip up to its nominal length: the sampler may have been
      # stopped mid-slot, or its final ticks dropped outright. This runs as the
      # clock's stop callback — i.e. on the sampler fiber, once its loop has
      # fully unwound — so it cannot interleave with a tick still in flight.
      # Padding from this fiber after `#stop` would race one: `#stop` only
      # clears a flag, and a tick suspended inside a blocking `input.write`
      # (a full ffmpeg pipe) resumes to finish its own writes afterwards,
      # overshooting `total`.
      #
      # Buffered: the sampler must never block handing off its "done", whether
      # or not this fiber is already waiting for it.
      done = Channel(Nil).new 1
      clock.stop_handler do
        while written < total
          input.write last
          written += 1
        end
      rescue
        # Pipe closed / encoder gone.
      ensure
        done.send nil
      end

      clock.start
      sleep duration
      clock.stop
      # The sampler observes `#stop` only when it next wakes (up to one frame
      # period), and pads on its way out; wait for that rather than returning
      # to a caller that would close the encoder's stdin under it.
      done.receive
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
      return unless c.artificial? && !c.hidden? && c.state != 0
      attr = @lines[y]?.try &.[x]?.try &.attr
      return unless attr
      artificial_cursor_attr c, attr
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
        line = @lines[y]?
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
    # `Rectangle` overload of `#dump`.
    def dump(rect : Rectangle, *, path : String? = nil) : String?
      dump rect.xi, rect.xl, rect.yi, rect.yl, path: path
    end

    def dump(xi : Number = 0, xl : Number = awidth, yi : Number = 0, yl : Number = aheight, *, path : String? = nil) : String?
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
