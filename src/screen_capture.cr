module Crysterm
  class Screen
    # The one entry point for capturing rendered/drawn screen content as an
    # image or a video. It captures what the *terminal* shows — the flushed cell
    # buffer rendered with a bitmap font, plus the in-band terminal-graphics
    # backends (sixel/kitty/iterm/regis) composited on top; external-helper and
    # separate-window backends are excluded (see `Crysterm::Capture`).
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
    # Still **PNG** is encoded in-process (no external tools). Every other format,
    # and any animation, is encoded by piping raw RGBA frames to `ffmpeg` — so
    # ffmpeg is only required when you ask for something other than a still PNG.
    #
    # Returns the encoded bytes when `path` is nil, otherwise `nil` (the output
    # is on disk). For a duration capture, call it from a fiber other than the one
    # running `Screen#exec`, so the UI keeps rendering while it records.
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
                font : Font = Font.default_normal,
                bold_font : Font = Font.default_bold,
                default_fg : Int32 = Capture::DEFAULT_FG,
                default_bg : Int32 = Capture::DEFAULT_BG,
                ffmpeg_args : Array(String)? = nil) : Bytes?
      xi = xi.to_i; xl = xl.to_i; yi = yi.to_i; yl = yl.to_i
      xi = 0 if xi < 0
      yi = 0 if yi < 0
      xl = awidth if xl > awidth
      yl = aheight if yl > aheight

      fmt = (format || (path ? File.extname(path).lchop('.') : nil)).to_s.downcase
      fmt = "png" if fmt.empty?

      if duration
        capture_animation(xi, xl, yi, yl, fmt, path, duration, fps, loops,
          font, bold_font, default_fg, default_bg, ffmpeg_args)
      elsif fmt == "png"
        # Still PNG: in-process, no ffmpeg.
        data = Capture.png(self, xi, xl, yi, yl, font, bold_font, default_fg, default_bg)
        if path
          File.write(path, data)
          nil
        else
          data
        end
      else
        # Still in a non-PNG format: one frame through ffmpeg.
        bmp = Capture.render(self, xi, xl, yi, yl, font, bold_font, default_fg, default_bg)
        vw = bmp[0]?.try(&.size) || 0
        vh = bmp.size
        run_ffmpeg(vw, vh, 1, fmt, path, loops, ffmpeg_args) do |input|
          input.write Capture.rgba(bmp)
        end
      end
    end

    # Records the region for *duration*, capturing one frame per screen render,
    # piping raw RGBA to ffmpeg.
    private def capture_animation(xi, xl, yi, yl, fmt, path, duration, fps, loops,
                                  font, bold_font, default_fg, default_bg, ffmpeg_args) : Bytes?
      first = Capture.render(self, xi, xl, yi, yl, font, bold_font, default_fg, default_bg)
      vw = first[0]?.try(&.size) || 0
      vh = first.size

      run_ffmpeg(vw, vh, fps, fmt, path, loops, ffmpeg_args) do |input|
        sub = on(::Crysterm::Event::Rendered) do
          begin
            bmp = Capture.render(self, xi, xl, yi, yl, font, bold_font, default_fg, default_bg)
            input.write Capture.rgba(bmp)
          rescue
            # Pipe closed / encoder gone: stop feeding it.
          end
        end
        input.write Capture.rgba(first) rescue nil
        sleep duration
        off ::Crysterm::Event::Rendered, sub
      end
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

      yield proc.input
      proc.input.close rescue nil

      result = out_ch.try &.receive
      proc.wait
      devnull.close
      result
    end
  end
end
