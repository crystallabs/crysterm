require "./spec_helper"

include Crysterm

# Regression spec for `Media::Cells#load`'s handling of a *streaming* video.
#
# A streaming video (`media.video_decode = stream`, or `auto` for a long clip)
# is decoded on demand by a live ffmpeg pipe. `Media::Base#source` opens that
# `Stream` and uses its 1-frame "vehicle" `PNGGIF::PNG` purely as the resampling
# dimension source; real frames arrive one at a time from the stream loop.
#
# `Media::Cells#load` (the `Ansi`/`Glyph` cell-grid backends) gated `@animated`
# — and therefore `#play` — on `frames.size > 1`. The vehicle has exactly one
# frame, so a streaming video never played: frozen first frame shown, and the
# launched ffmpeg subprocess sat open but unread. (In-band graphics backends
# avoided this via `#ensure_animation`, which plays on any non-nil `frames`.)
# Fix: also treat a non-nil `@stream` as animated, so the stream loop runs and
# cell backends play streaming video too.

private def headless_screen
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 80, height: 24)
end

describe "Media::Cells streaming video" do
  it "plays a streaming video on a cell-grid backend" do
    gif = "data/image/netscape.gif"
    have_ffmpeg = !Process.find_executable("ffmpeg").nil? &&
                  !Process.find_executable("ffprobe").nil?
    pending! "ffmpeg/ffprobe not available" unless have_ffmpeg
    pending! "no video fixture" unless File.exists?(gif)

    # Route through `Media::VideoSource` (keyed on the .mp4 extension);
    # ffmpeg/ffprobe read by content, so the GIF decodes fine.
    tmp = File.tempfile("crysterm_vid", ".mp4")
    File.write(tmp.path, File.read(gif))

    prev = Crysterm::Config.media_video_decode
    Crysterm::Config.media_video_decode = Crysterm::Widget::Media::VideoDecode::Stream

    s = headless_screen
    img = Crysterm::Widget::Media::Ansi.new(
      file: tmp.path, parent: s, top: 0, left: 0, width: 8, height: 4)

    # `#load` opened the live stream during construction; with the fix it also
    # started playback (previously `@animated` stayed false, `#play` was never
    # called, freezing on the first frame and leaking the ffmpeg pipe).
    img.playing?.should be_true
  ensure
    img.try &.stop # closes the ffmpeg pipe / halts the stream loop
    s.try &.destroy
    Crysterm::Config.media_video_decode = prev if prev
    tmp.try &.delete rescue nil
  end
end
