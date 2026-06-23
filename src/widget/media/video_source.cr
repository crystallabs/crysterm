require "../media"

module Crysterm
  class Widget
    # Decodes a video file into animation frames using the external `ffmpeg`
    # (with `ffprobe` for dimensions/frame rate), so the existing
    # `Widget::Media` backends can play it exactly like an animated GIF.
    #
    # This is the **Tier-1, eager** decoder: it reads every frame up front into
    # memory (at a capped resolution — terminal boxes are tiny), which is fine
    # for short clips but not for long videos (a streaming frame provider would
    # be Tier 2). ffmpeg is asked to scale frames down and emit raw RGBA on
    # stdout; each frame is `w*h*4` bytes, converted straight into a
    # `PNGGIF::Bitmap` and wrapped in a frame-backed `PNGGIF::PNG`
    # (`PNGGIF::PNG.from_frames`) that every backend already knows how to
    # animate.
    #
    # It never raises: when `ffmpeg`/`ffprobe` are missing or decoding fails,
    # `#decode` returns `nil` and the caller falls back to its usual "could not
    # load" state.
    module Media::VideoSource
      extend self

      # File extensions routed through ffmpeg as video. (`.ogg` is intentionally
      # excluded — it's commonly audio-only; use `.ogv` for Ogg video.)
      EXTENSIONS = %w[mp4 m4v mkv webm mov avi wmv flv mpg mpeg mpe ogv ts 3gp]

      # Decoded video stream metadata from ffprobe.
      record Info, width : Int32, height : Int32, fps : Float64

      # Whether *file* looks like a video this module should decode.
      def video?(file : String) : Bool
        EXTENSIONS.includes? File.extname(file).lstrip('.').downcase
      end

      # Decodes *file* into a frame-backed `PNGGIF::PNG`, or `nil` on any
      # failure. *cap* is the long-edge pixel size frames are scaled to;
      # *max_fps* caps the sampled frame rate.
      def decode(file : String,
                 cap : Int32 = Crysterm::Config.video_max_size,
                 max_fps : Float64 = Crysterm::Config.video_fps) : PNGGIF::PNG?
        info = probe(file) || return nil
        w, h = cap_size info.width, info.height, cap
        fps = info.fps > 0 ? {info.fps, max_fps}.min : max_fps
        fps = 1.0 if fps <= 0
        frames = read_frames file, w, h, fps, Crysterm::Config.video_max_frames
        return nil if frames.nil? || frames.empty?
        delay = (1000.0 / fps).round.to_i
        delay = 1 if delay < 1
        PNGGIF::PNG.from_frames frames.map { |bmp| {bmp, delay} }, w, h, num_plays: 0
      rescue
        nil
      end

      # Reads width / height / average frame rate via ffprobe. Returns `nil` if
      # ffprobe is missing or the file has no usable video stream.
      private def probe(file : String) : Info?
        stdout = IO::Memory.new
        status = Process.run("ffprobe", [
          "-v", "error", "-select_streams", "v:0",
          "-show_entries", "stream=width,height,avg_frame_rate",
          "-of", "default=noprint_wrappers=1:nokey=0", file,
        ], output: stdout, error: Process::Redirect::Close)
        return nil unless status.success?

        w = h = 0
        fps = 0.0
        stdout.to_s.each_line do |line|
          key, _, val = line.partition('=')
          case key.strip
          when "width"  then w = val.to_i? || 0
          when "height" then h = val.to_i? || 0
          when "avg_frame_rate"
            num, _, den = val.partition('/')
            n = num.to_f? || 0.0
            d = den.to_f? || 0.0
            fps = d > 0 ? n / d : n
          end
        end
        return nil if w <= 0 || h <= 0
        Info.new w, h, fps
      rescue
        nil
      end

      # Caps *sw*×*sh* to a *cap* long edge (preserving aspect), forcing even
      # dimensions (yuv420-based codecs require even width/height).
      private def cap_size(sw : Int32, sh : Int32, cap : Int32) : Tuple(Int32, Int32)
        w, h = sw, sh
        if sw > cap || sh > cap
          if sw >= sh
            w = cap
            h = (sh * cap / sw).round.to_i
          else
            h = cap
            w = (sw * cap / sh).round.to_i
          end
        end
        w -= w % 2
        h -= h % 2
        w = 2 if w < 2
        h = 2 if h < 2
        {w, h}
      end

      # Runs ffmpeg to decode the video to raw RGBA frames of *w*×*h* at *fps*,
      # returning one `PNGGIF::Bitmap` per frame (or `nil` on failure). Stops
      # after *max_frames* (closing the pipe ends ffmpeg) so an accidentally huge
      # video can't exhaust memory in this eager Tier-1 decoder.
      private def read_frames(file : String, w : Int32, h : Int32, fps : Float64,
                              max_frames : Int32) : Array(PNGGIF::Bitmap)?
        frame_bytes = w * h * 4
        frames = [] of PNGGIF::Bitmap
        Process.run("ffmpeg", [
          "-hide_banner", "-loglevel", "error",
          "-i", file,
          "-vf", "fps=#{fps},scale=#{w}:#{h}:flags=bilinear",
          "-f", "rawvideo", "-pix_fmt", "rgba", "pipe:1",
        ], input: Process::Redirect::Close,
          output: Process::Redirect::Pipe,
          error: Process::Redirect::Close) do |proc|
          io = proc.output
          buf = Bytes.new(frame_bytes)
          while frames.size < max_frames && read_full(io, buf)
            frames << to_bitmap(buf, w, h)
          end
        end
        # `Process.run`'s block form waits for (and reaps) the process on exit,
        # even when we stop reading early or an exception unwinds through it.
        frames.empty? ? nil : frames
      rescue
        nil
      end

      # Reads exactly `buf.size` bytes into *buf*, returning `false` at EOF (a
      # short trailing read — e.g. a truncated final frame — is discarded).
      private def read_full(io : IO, buf : Bytes) : Bool
        off = 0
        while off < buf.size
          n = io.read(buf + off)
          return false if n == 0
          off += n
        end
        true
      end

      # Converts one raw RGBA frame buffer into a `PNGGIF::Bitmap`.
      private def to_bitmap(buf : Bytes, w : Int32, h : Int32) : PNGGIF::Bitmap
        Array(Array(PNGGIF::Pixel)).new(h) do |y|
          base = y * w * 4
          Array(PNGGIF::Pixel).new(w) do |x|
            i = base + x * 4
            PNGGIF::Pixel.new(buf[i].to_i, buf[i + 1].to_i, buf[i + 2].to_i, buf[i + 3].to_i)
          end
        end
      end
    end
  end
end
