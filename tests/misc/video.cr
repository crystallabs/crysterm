# FEATURE: video playback.
#
# `Widget::Video` plays a video file in the terminal: external ffmpeg/ffprobe
# decode the frames, and the best available `Widget::Media` backend renders
# them like an animated image — animation loop, `fit:`, resize and
# `play`/`pause`/`stop` all included. Short clips are decoded eagerly into
# RAM and looped for free; long ones stream at constant memory
# (`media.video_decode: auto | eager | stream`).
#
# Self-contained: the demo converts the bundled netscape.gif into a small
# cached MP4 on first run (needs ffmpeg on PATH).

require "../../src/crysterm"

include Crysterm

# Build (once) a small MP4 out of the bundled GIF, cached outside the repo so
# reruns start instantly.
mp4 = Path[Dir.tempdir] / "crysterm_demo_netscape.mp4"
unless File.exists? mp4
  gif = "#{__DIR__}/../../data/image/netscape.gif"
  status = Process.run "ffmpeg",
    ["-y", "-hide_banner", "-loglevel", "error", "-i", gif,
     "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", "-pix_fmt", "yuv420p", mp4.to_s],
    error: Process::Redirect::Inherit
  abort "video.cr: ffmpeg not on PATH or conversion failed" unless status.success?
end

s = Window.new title: "Video"

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Video playback · ffmpeg decodes, the best Media backend renders · looping{/center}",
  parse_tags: true, style: Style.new(fg: "white", bg: "#202830")

Widget::Video.new \
  parent: s, file: mp4.to_s, fit: Widget::Media::Fit::Contain,
  top: 1, left: 0, width: "100%", height: s.aheight - 3,
  label: " netscape.mp4 · media.video_decode=auto ",
  style: Style.new(border: true)

Widget::Box.new \
  parent: s, top: s.aheight - 2, left: 0, width: "100%", height: 2,
  content: "{center}containers: mp4 m4v mkv webm mov avi wmv flv mpg mpeg ogv ts 3gp\n" \
           "decode tiers: eager (short clips, loop from RAM) · stream (constant memory){/center}",
  parse_tags: true, style: Style.new(fg: "#8090a0")

s.exec
