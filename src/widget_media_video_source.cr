require "./widget/media"

module Crysterm
  class Widget
    # Decodes a video file into animation frames using external `ffmpeg` (with
    # `ffprobe` for dimensions/frame rate), so the existing `Widget::Media`
    # backends can play it like an animated GIF. ffmpeg scales frames to a small
    # cap and emits raw RGBA on stdout; each frame is `w*h*4` bytes, converted
    # into a `PNGGIF::Bitmap`.
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

      # File extensions routed through ffmpeg as video. `.ogg` is excluded
      # (commonly audio-only); use `.ogv` for Ogg video.
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
        case Crysterm::Config.media_video_decode
        in .eager?  then Mode::Eager
        in .stream? then Mode::Stream
        in .auto?
          est = estimate_frames file
          (est && est > Crysterm::Config.video_max_frames) ? Mode::Stream : Mode::Eager
        end
      end

      # Probes *file* and resolves the capped frame dimensions and sampled fps as
      # `{w, h, fps}`, or `nil` when ffprobe can't read it. Shared setup for both
      # eager `#decode` and streaming `Stream.open`.
      # :nodoc:
      def resolve_geometry(file : String, cap : Int32, max_fps : Float64) : Tuple(Int32, Int32, Float64)?
        info = probe(file) || return nil
        w, h = cap_size info.width, info.height, cap
        fps = sample_fps info.fps, max_fps
        {w, h, fps}
      end

      # Decodes *file* eagerly into a frame-backed `PNGGIF::PNG`, or `nil` on any
      # failure. *cap* is the long-edge pixel size frames are scaled to;
      # *max_fps* caps the sampled frame rate.
      def decode(file : String,
                 cap : Int32 = Crysterm::Config.video_max_size,
                 max_fps : Float64 = Crysterm::Config.video_fps) : PNGGIF::PNG?
        w, h, fps = resolve_geometry(file, cap, max_fps) || return nil
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
        # A 1-frame `PNGGIF::PNG` (first frame + true canvas dims) used as the
        # resampling vehicle (`create_cellmap`) and dimension source by the
        # backends; live per-frame bitmaps come from `#next_frame`.
        getter vehicle : PNGGIF::PNG

        # Per-frame delay in ms (from the sampled fps).
        getter delay : Int32

        @process : Process?
        @buf : Bytes
        @pending : PNGGIF::Bitmap? # the already-read first frame, returned first

        # Two preallocated bitmaps ping-ponged by `#read_ppong`, so a streamed
        # frame overwrites pixels in place (`PNGGIF::Pixel` is a value struct, so
        # reassigning a row slot mutates the stored pixel with no allocation)
        # instead of building a fresh `h`-array-of-`w`-arrays bitmap every tick.
        # Two (not one) keep the downstream identity checks — `FrameMemo`'s
        # `entry[0].same?(bmp)` and the graphics per-frame payload cache — seeing
        # each frame as new content (consecutive frames are distinct objects),
        # while `invalidate_frame(0)` still clears the caches. Allocated lazily on
        # first use, reused for the stream's whole life (dimensions are fixed at
        # construction, but `#read_ppong` reallocates if @w/@h ever change).
        @ppong_a : PNGGIF::Bitmap?
        @ppong_b : PNGGIF::Bitmap?
        @ppong_toggle = false

        # Opens a stream for *file*, or `nil` if ffmpeg/ffprobe are missing or the
        # first frame can't be read.
        def self.open(file : String,
                      cap : Int32 = Crysterm::Config.video_max_size,
                      max_fps : Float64 = Crysterm::Config.video_fps) : Stream?
          w, h, fps = VideoSource.resolve_geometry(file, cap, max_fps) || return nil
          new file, w, h, fps
        rescue
          nil
        end

        # :nodoc:
        def initialize(@file : String, @w : Int32, @h : Int32, @fps : Float64)
          @delay = VideoSource.frame_delay @fps
          @buf = Bytes.new(@w * @h * 4)
          @process = launch
          @pending, @vehicle = open_first
        end

        # Reads the first frame and builds the resampling vehicle, reaping ffmpeg
        # on failure (undecodable file, no frames) to avoid leaking a zombie
        # process; `Stream.open` turns the re-raised failure into `nil`.
        private def open_first : Tuple(PNGGIF::Bitmap, PNGGIF::PNG)
          first = read_one
          raise "no video frames" unless first
          # `first` is a ping-pong buffer that a later frame will overwrite; give
          # the vehicle (which persists for the stream's whole life) an
          # independent copy so it can never be mutated out from under it.
          {first, PNGGIF::PNG.from_frames([{VideoSource.dup_bitmap(first), @delay}], @w, @h)}
        rescue ex
          close
          raise ex
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
          first = read_one
          if first.nil?
            close # reap the just-relaunched ffmpeg; nothing decodable to play
            return false
          end
          @pending = first
          true
        rescue
          close # don't leak the relaunched subprocess on an unexpected failure
          false
        end

        # Terminates and reaps the ffmpeg subprocess. Idempotent.
        #
        # Uses SIGKILL, not SIGTERM: ffmpeg is usually blocked writing to a
        # back-filled stdout pipe between frames and can't act on a trapped
        # SIGTERM, which would make `wait` hang. SIGKILL can't be trapped.
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
          read_ppong
        rescue
          nil
        end

        # Decodes the just-read `@buf` into one of the two ping-pong bitmaps,
        # overwriting its pixels in place, and alternates which buffer is used so
        # consecutive returned frames are distinct objects (see the ivar note).
        # The buffers are allocated lazily and reused for the stream's life;
        # they're reallocated only if @w/@h somehow change after construction.
        private def read_ppong : PNGGIF::Bitmap
          @ppong_toggle = !@ppong_toggle
          bmp =
            if @ppong_toggle
              @ppong_a ||= VideoSource.blank_bitmap(@w, @h)
            else
              @ppong_b ||= VideoSource.blank_bitmap(@w, @h)
            end
          # Guard against a dimension change: if the cached buffer no longer
          # matches @w×@h, replace it (keeps the in-place fill valid).
          if bmp.size != @h || (bmp[0]?.try(&.size) || 0) != @w
            bmp = VideoSource.blank_bitmap(@w, @h)
            @ppong_toggle ? (@ppong_a = bmp) : (@ppong_b = bmp)
          end
          VideoSource.fill_bitmap bmp, @buf, @w, @h
          bmp
        end
      end

      # Estimates the total frame count via ffprobe (nb_frames, else
      # duration × fps), or `nil` when unknown.
      def estimate_frames(file : String) : Int32?
        fields = ffprobe_fields(file, "nb_frames,avg_frame_rate,duration") || return nil
        nb = fields["nb_frames"]?.try(&.to_i?) || 0
        return nb if nb > 0
        dur = fields["duration"]?.try(&.to_f?) || 0.0
        fps = parse_frame_rate fields["avg_frame_rate"]?
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
        fields = ffprobe_fields(file, "width,height,avg_frame_rate") || return nil
        w = fields["width"]?.try(&.to_i?) || 0
        h = fields["height"]?.try(&.to_i?) || 0
        return nil if w <= 0 || h <= 0
        Info.new w, h, parse_frame_rate(fields["avg_frame_rate"]?)
      rescue
        nil
      end

      # Runs ffprobe for the first video stream, requesting *entries* (a
      # comma-separated `stream=…` field list), and returns the printed
      # `key => value` pairs — or `nil` if ffprobe is missing / fails.
      # :nodoc:
      def ffprobe_fields(file : String, entries : String) : Hash(String, String)?
        stdout = IO::Memory.new
        status = Process.run("ffprobe", [
          "-v", "error", "-select_streams", "v:0",
          "-show_entries", "stream=#{entries}",
          "-of", "default=noprint_wrappers=1:nokey=0", file,
        ], output: stdout, error: Process::Redirect::Close)
        return nil unless status.success?
        fields = {} of String => String
        stdout.to_s.each_line do |line|
          key, _, val = line.partition('=')
          fields[key.strip] = val
        end
        fields
      rescue
        nil
      end

      # Parses an ffprobe `avg_frame_rate` value (`"num/den"`) into fps, or `0.0`
      # when unset/unusable.
      # :nodoc:
      def parse_frame_rate(val : String?) : Float64
        return 0.0 unless val
        num, _, den = val.partition('/')
        n = num.to_f? || 0.0
        d = den.to_f? || 0.0
        d > 0 ? n / d : n
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
      # after *max_frames* (closing the pipe ends ffmpeg) to cap memory use.
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
        # `Process.run`'s block form reaps the process on exit even if we stop
        # reading early or an exception unwinds through it.
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

      # Deep-copies a bitmap (new outer + inner arrays) so a caller can retain a
      # snapshot that won't be mutated when a ping-pong buffer is later reused.
      # :nodoc:
      def dup_bitmap(bmp : PNGGIF::Bitmap) : PNGGIF::Bitmap
        bmp.map(&.dup)
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

      # Allocates a *w*×*h* fully-transparent bitmap for in-place reuse by the
      # `Stream` ping-pong. (`PNGGIF::Pixel` is a value struct, so `Array.new`
      # fills the row with independent copies — no shared reference.)
      # :nodoc:
      def blank_bitmap(w : Int32, h : Int32) : PNGGIF::Bitmap
        Array(Array(PNGGIF::Pixel)).new(h) { Array(PNGGIF::Pixel).new(w, PNGGIF::Pixel.new(0, 0, 0, 0)) }
      end

      # Overwrites *bmp* in place from the raw RGBA frame in *buf*, reusing the
      # existing row/outer arrays (only the value-struct pixels are reassigned).
      # *bmp* must already be sized *w*×*h*.
      # :nodoc:
      def fill_bitmap(bmp : PNGGIF::Bitmap, buf : Bytes, w : Int32, h : Int32) : Nil
        y = 0
        while y < h
          base = y * w * 4
          row = bmp[y]
          x = 0
          while x < w
            i = base + x * 4
            row[x] = PNGGIF::Pixel.new(buf[i].to_i, buf[i + 1].to_i, buf[i + 2].to_i, buf[i + 3].to_i)
            x += 1
          end
          y += 1
        end
      end
    end
  end
end
