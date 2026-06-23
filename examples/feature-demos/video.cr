# IMPRESSIVE DEMO: a video file played inside the terminal.
#
# `Widget::Video` is a thin factory: an external `ffmpeg`/`ffprobe` decoder
# (`Media::VideoSource`) turns the file into animation frames, and the best
# video-capable image backend for *this* terminal — Kitty, Sixel, Glyph or Ansi,
# chosen by `Media.resolve(Content::Video)` and the `image.exclude` umask —
# renders them like an animated GIF. So the same code plays as real raster
# graphics on a kitty/sixel terminal and as colored cells/Unicode glyphs
# anywhere else.
#
# Pass a file as ARGV[0]; otherwise a short test clip is synthesized with ffmpeg
# into a temp file. Force a backend with `MEDIA_BACKEND=glyph` (or sixel/kitty/
# ansi), or exclude some with `MEDIA_EXCLUDE=kitty,sixel`. Pick the decode
# strategy with `MEDIA_VIDEO_DECODE=eager|stream|auto` (auto: streams long
# videos at constant memory, loads short clips eagerly for free looping).
#
# Requires ffmpeg + ffprobe on PATH.

require "../../src/crysterm"

include Crysterm

# Resolve a video file: ARGV, or synthesize a 4s test pattern with ffmpeg.
path = ARGV[0]?
if path.nil?
  path = File.join(Dir.tempdir, "crysterm-video-demo.mp4")
  unless File.exists? path
    ok = Process.run("ffmpeg", [
      "-hide_banner", "-loglevel", "error", "-y",
      "-f", "lavfi", "-i", "testsrc=size=320x240:rate=15:duration=4",
      "-pix_fmt", "yuv420p", path,
    ]).success? rescue false
    unless ok && File.exists?(path)
      STDERR.puts "Could not create a test clip (is ffmpeg installed?). Pass a video file as the first argument."
      exit 1
    end
  end
end

# Let the env pick/exclude backends so one demo exercises every render path.
Crysterm::Config.media_backend = ENV["MEDIA_BACKEND"]? || "auto"
Crysterm::Config.media_exclude = ENV["MEDIA_EXCLUDE"]? || ""
Crysterm::Config.media_video_decode = ENV["MEDIA_VIDEO_DECODE"]? || "auto"

s = Screen.new title: "Video"

backend = Widget::Media.resolve Widget::Media::Content::Video

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Widget::Video  ·  ffmpeg → frames → #{backend} backend  ·  #{File.basename(path)}{/center}",
  parse_tags: true, style: Style.new(fg: "white", bg: "#202830")

Widget::Video.new \
  parent: s, top: 1, left: 0, width: s.awidth, height: s.aheight - 2,
  fit: Widget::Media::Fit::Contain,
  file: path

# Self-terminate for the screenshot/CI tooling.
if secs = ENV["DEMO_SECONDS"]?
  spawn do
    sleep secs.to_f.seconds
    s.destroy
    exit
  end
end

s.render
s.exec
