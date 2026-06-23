require "../media"

module Crysterm
  class Widget
    # Decodes a video file into animation frames using the external `ffmpeg`
    # (with `ffprobe` for dimensions/frame rate), so the existing
    # `Widget::Media` backends can play it like an animated GIF. ffmpeg is asked
    # to scale frames to a small cap (terminal boxes are tiny) and emit raw RGBA
    # on stdout; each frame is `w*h*4` bytes, converted into a `PNGGIF::Bitmap`.
    #
    # Two decoders, chosen per `media.video_decode` (`auto` by default):
    #
    # * **Eager** (`#decode`) — reads every frame up front into a frame-backed
    #   `PNGGIF::PNG` (capped by `video.max_frames`). Best for short, *looping*
    #   clips: decode once, loop from RAM for free, instant resize re-sample.
    # * **Streaming** (`Stream`) — a live ffmpeg pipe yielding frames on demand,
    #   constant memory regardless of length, fast first paint, re-decodes on
    #   loop. Best for long videos that can't fit in memory.
    #
    # `auto` picks streaming when the estimated frame count exceeds
    # `video.max_frames`, else eager. Nothing here raises: failures yield `nil`
    # and the caller falls back to its usual "could not load" state.
    module Media::VideoSource
      extend self

      # File extensions routed through ffmpeg as video. (`.ogg` is intentionally
      # excluded — it's commonly audio-only; use `.ogv` for Ogg video.)
      EXTENSIONS = %w[mp4 m4v mkv webm mov avi wmv flv mpg mpeg mpe ogv ts 3gp]

      # Decoder strategy for a video source.
      enum Mode
        Eager  # decode all frames into memory (short, looping clips)
        Stream # decode on demand via a live ffmpeg pipe (long videos)
      end

      # Decoded video stream metadata from ffprobe.
      record Info, width : Int32, height : Int32, fps : Float64

      # Whether *file* looks like a video this module should decode.
      def video?(file : String) : Bool
        EXTENSIONS.includes? File.extname(file).lstrip('.').downcase
      end

      # Resolves the decoder strategy for *file* from the `media.video_decode`
      # config (`auto` | `eager` | `stream`). `auto` streams when the estimated
      # frame count exceeds `video.max_frames` (an unknown length stays eager —
      # the cap then protects memory by truncation).
      def mode(file : String) : Mode
        case Crysterm::Config.media_video_decode.downcase
        when "eager"  then Mode::Eager
        when "stream" then Mode::Stream
        else
          est = estimate_frames file
          (est && est > Crysterm::Config.video_max_frames) ? Mode::Stream : Mode::Eager
        end
      end

      # Decodes *file* eagerly into a frame-backed `PNGGIF::PNG`, or `nil` on any
      # failure. *cap* is the long-edge pixel size frames are scaled to;
      # *max_fps* caps the sampled frame rate.
      def decode(file : String,
                 cap : Int32 = Crysterm::Config.video_max_size,
                 max_fps : Float64 = Crysterm::Config.video_fps) : PNGGIF::PNG?
        info = probe(file) || return nil
        w, h = cap_size info.width, info.height, cap
        fps = sample_fps info.fps, max_fps
        frames = read_frames file, w, h, fps, Crysterm::Config.video_max_frames
        return nil if frames.nil? || frames.empty?
        delay = frame_delay fps
        PNGGIF::PNG.from_frames frames.map { |bmp| {bmp, delay} }, w, h, num_plays: 0
      rescue
        nil
      end

      # A live, on-demand video decoder: a running `ffmpeg` whose raw-RGBA frames
      # are pulled one at a time. Constant memory, fast first paint, re-decodes
      # from the start on `#restart` (for looping). Always `#close` it to reap the
      # subprocess. Build via `Stream.open` (returns `nil` on failure).
      class Stream
        # A 1-frame `PNGGIF::PNG` (first frame + true canvas dims) used purely as
        # the resampling vehicle (`create_cellmap`) and dimension source by the
        # backends; the live per-frame bitmaps come from `#next_frame`.
        getter vehicle : PNGGIF::PNG

        # Per-frame delay in ms (from the sampled fps).
        getter delay : Int32

        @process : Process?
        @buf : Bytes
        @pending : PNGGIF::Bitmap? # the already-read first frame, returned first

        # Opens a stream for *file*, or `nil` if ffmpeg/ffprobe are missing or the
        # first frame can't be read.
        def self.open(file : String,
                      cap : Int32 = Crysterm::Config.video_max_size,
                      max_fps : Float64 = Crysterm::Config.video_fps) : Stream?
          info = VideoSource.probe(file) || return nil
          w, h = VideoSource.cap_size info.width, info.height, cap
          fps = VideoSource.sample_fps info.fps, max_fps
          new file, w, h, fps
        rescue
          nil
        end

        # :nodoc:
        def initialize(@file : String, @w : Int32, @h : Int32, @fps : Float64)
          @delay = VideoSource.frame_delay @fps
          @buf = Bytes.new(@w * @h * 4)
          @process = launch
          first = read_one
          raise "no video frames" unless first
          @pending = first
          @vehicle = PNGGIF::PNG.from_frames([{first, @delay}], @w, @h)
        end

        # The next decoded frame, or `nil` at end-of-stream.
        def next_frame : PNGGIF::Bitmap?
          if p = @pending
            @pending = nil
            return p
          end
          read_one
        end

        # Restarts ffmpeg from the beginning (for looping); `false` on failure.
        def restart : Bool
          close
          @process = launch
          first = read_one || return false
          @pending = first
          true
        rescue
          false
        end

        # Terminates and reaps the ffmpeg subprocess. Idempotent.
        #
        # Uses SIGKILL, not SIGTERM: playback pauses between frames, so ffmpeg is
        # usually blocked writing to a back-filled stdout pipe, where it can't act
        # on the SIGTERM it traps for graceful shutdown — `wait` would then hang.
        # SIGKILL can't be trapped, so it dies immediately and `wait` reaps it.
        def close : Nil
          pr = @process
          @process = nil
          return unless pr
          pr.terminate(graceful: false) rescue nil
          pr.wait rescue nil
        end

        private def launch : Process
          Process.new "ffmpeg", VideoSource.ffmpeg_args(@file, @w, @h, @fps),
            input: Process::Redirect::Close,
            output: Process::Redirect::Pipe,
            error: Process::Redirect::Close
        end

        private def read_one : PNGGIF::Bitmap?
          pr = @process || return nil
          return nil unless VideoSource.read_full(pr.output, @buf)
          VideoSource.to_bitmap @buf, @w, @h
        rescue
          nil
        end
      end

      # Estimates the total frame count via ffprobe (nb_frames, else
      # duration × fps), or `nil` when unknown.
      def estimate_frames(file : String) : Int32?
        stdout = IO::Memory.new
        status = Process.run("ffprobe", [
          "-v", "error", "-select_streams", "v:0",
          "-show_entries", "stream=nb_frames,avg_frame_rate,duration",
          "-of", "default=noprint_wrappers=1:nokey=0", file,
        ], output: stdout, error: Process::Redirect::Close)
        return nil unless status.success?
        nb = 0
        dur = 0.0
        fps = 0.0
        stdout.to_s.each_line do |line|
          key, _, val = line.partition('=')
          case key.strip
          when "nb_frames" then nb = val.to_i? || 0
          when "duration"  then dur = val.to_f? || 0.0
          when "avg_frame_rate"
            num, _, den = val.partition('/')
            n = num.to_f? || 0.0
            d = den.to_f? || 0.0
            fps = d > 0 ? n / d : n
          end
        end
        return nb if nb > 0
        return (dur * fps).to_i if dur > 0 && fps > 0
        nil
      rescue
        nil
      end

      # ffmpeg argv that decodes *file* to raw RGBA frames of *w*×*h* at *fps*.
      # :nodoc:
      def ffmpeg_args(file : String, w : Int32, h : Int32, fps : Float64) : Array(String)
        ["-hide_banner", "-loglevel", "error",
         "-i", file,
         "-vf", "fps=#{fps},scale=#{w}:#{h}:flags=bilinear",
         "-f", "rawvideo", "-pix_fmt", "rgba", "pipe:1"]
      end

      # The sampled fps: the source rate capped to *max_fps* (never below 1).
      # :nodoc:
      def sample_fps(src_fps : Float64, max_fps : Float64) : Float64
        fps = src_fps > 0 ? {src_fps, max_fps}.min : max_fps
        fps <= 0 ? 1.0 : fps
      end

      # Per-frame delay in ms for *fps* (at least 1).
      # :nodoc:
      def frame_delay(fps : Float64) : Int32
        d = (1000.0 / fps).round.to_i
        d < 1 ? 1 : d
      end

      # Reads width / height / average frame rate via ffprobe. Returns `nil` if
      # ffprobe is missing or the file has no usable video stream.
      # :nodoc:
      def probe(file : String) : Info?
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
      # :nodoc:
      def cap_size(sw : Int32, sh : Int32, cap : Int32) : Tuple(Int32, Int32)
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
      # video can't exhaust memory in this eager decoder.
      private def read_frames(file : String, w : Int32, h : Int32, fps : Float64,
                              max_frames : Int32) : Array(PNGGIF::Bitmap)?
        frames = [] of PNGGIF::Bitmap
        Process.run("ffmpeg", ffmpeg_args(file, w, h, fps),
          input: Process::Redirect::Close,
          output: Process::Redirect::Pipe,
          error: Process::Redirect::Close) do |proc|
          io = proc.output
          buf = Bytes.new(w * h * 4)
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
      # :nodoc:
      def read_full(io : IO, buf : Bytes) : Bool
        off = 0
        while off < buf.size
          n = io.read(buf + off)
          return false if n == 0
          off += n
        end
        true
      end

      # Converts one raw RGBA frame buffer into a `PNGGIF::Bitmap`.
      # :nodoc:
      def to_bitmap(buf : Bytes, w : Int32, h : Int32) : PNGGIF::Bitmap
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
