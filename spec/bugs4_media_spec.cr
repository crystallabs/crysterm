require "./spec_helper"

include Crysterm

# Regression spec: a *finite* animation that ran to
# completion holds its last frame. Calling `#play` again must rewind
# to frame 0 and replay — otherwise the loop starts already at the last
# frame and immediately re-completes, only flashing that frame. A `@finished`
# flag distinguishes "done" from "paused mid-stream" so `#play` rewinds only on
# completion.

private def write_apng(path : String, nframes : Int32, num_plays : Int32,
                       w = 4, h = 4, delay = 20)
  frames = [] of Tuple(PNGGIF::Bitmap, Int32)
  nframes.times do |i|
    v = ((i * 60) % 256).to_u8
    bmp = Array.new(h) { Array.new(w) { PNGGIF::Pixel.new(v, 0u8, 0u8, 255u8) } }
    frames << {bmp, delay}
  end
  File.write path, PNGGIF.encode_apng(frames, num_plays: num_plays)
end

describe "Widget::Media::Base finite-animation replay (BUGS4)" do
  it "rewinds to frame 0 when replayed after a finite loop completes" do
    path = File.tempname("bugs4_replay", ".png")
    write_apng path, 3, 1 # 3 frames, play once
    begin
      s = headless_screen(10, 5, default_quit_keys: true)
      img = Crysterm::Widget::Media::Sixel.new file: path, parent: s, width: 4, height: 3
      img.play
      # Let the compose fiber build frames and the clock run to completion.
      wait_until { !img.playing? }

      img.playing?.should be_false   # finite loop finished
      img.anim_index.should eq 3 - 1 # holding the last frame (BUGS3 behavior)

      # Replay: `#play` must synchronously rewind to frame 0 (before any tick
      # advances it) and start a genuine playback again — not flash the last
      # frame and stop.
      img.play
      img.anim_index.should eq 0
      img.playing?.should be_true
    ensure
      img.try &.stop
      s.try &.destroy
    end
  ensure
    File.delete?(path) if path
  end
end
