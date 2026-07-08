require "./spec_helper"

include Crysterm

# Regression spec for BUGS11 #12 (src/widget_media_base.cr `animate_loop`).
#
# The FrameClock tick used to render-then-advance: it flagged a render, read the
# CURRENT frame's delay, advanced `@anim_index`, and set the next interval from
# the pre-advance frame. Because `request_render` only flags a render that runs
# after the (cooperative) tick block returns, the deferred render always sampled
# the ALREADY-advanced index — so frame i+1 was shown for frame i's delay, and
# the very first tick (which FrameClock fires immediately) advanced 0->1, so
# frame 0 was never displayed for its own delay.
#
# The fix advances at the START of each tick (skipping the very first via a
# `first` closure flag), THEN renders and sets the interval from the frame
# actually being displayed. With variable per-frame delays this is observable:
# after the immediate first tick, `@anim_index` must still be 0 (frame 0 is the
# one being displayed) and the clock interval must be frame 0's own delay
# (2000ms), NOT frame 1's (50ms).

private def headless_window(w = 10, h = 5)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

# Builds an APNG with explicit per-frame delays (ms). These values round-trip
# exactly through the APNG encoder/decoder (delay_num = ms, delay_den = 1000).
private def write_apng_delays(path : String, delays : Array(Int32),
                              num_plays : Int32 = 0, w = 4, h = 4)
  frames = [] of Tuple(PNGGIF::Bitmap, Int32)
  delays.each_with_index do |delay, i|
    v = ((i * 80) % 256).to_u8
    bmp = Array.new(h) { Array.new(w) { PNGGIF::Pixel.new(v, 0u8, 0u8, 255u8) } }
    frames << {bmp, delay}
  end
  File.write path, PNGGIF.encode_apng(frames, num_plays: num_plays)
end

# Exposes the private frame clock so the spec can read its live interval.
private class ProbeSixel < Crysterm::Widget::Media::Sixel
  def animation_clock : Crysterm::FrameClock?
    @animation
  end
end

describe "Widget::Media::Base animate_loop per-frame delay (BUGS11 #12)" do
  it "displays frame 0 for its own delay (not the next frame's)" do
    path = File.tempname("bugs11_media", ".png")
    # Frame 0 has a long delay; frames 1 and 2 short. A render-then-advance loop
    # would immediately jump to frame 1 and hold it for frame 0's 2000ms.
    write_apng_delays path, [2000, 50, 50], num_plays: 0
    begin
      s = headless_window
      img = ProbeSixel.new file: path, parent: s, width: 4, height: 3
      img.play

      # Let the compose fiber build @src_frames, start the clock, and fire the
      # immediate first tick (which then sleeps 2000ms before tick 2).
      100.times do
        break if img.frames_ready? && img.animation_clock
        sleep 0.01.seconds
      end
      sleep 0.05.seconds # let the immediate first tick run

      clock = img.animation_clock
      clock.should_not be_nil
      clock = clock.not_nil!

      # After the first tick, frame 0 must still be the frame being displayed:
      # the render (deferred until the tick returns) samples @anim_index, and it
      # must sample 0, not the advanced 1. (Old code left it at 1 here.)
      img.anim_index.should eq 0

      # ...and it must be held for frame 0's OWN delay (2000ms), not frame 1's
      # 50ms. If tick 2 had already advanced us it would be far in the future,
      # so we are safely inside frame 0's window here.
      clock.interval.should eq 2000.milliseconds
    ensure
      img.try &.stop
      s.try &.destroy
    end
  ensure
    File.delete?(path) if path
  end

  it "wraps to frame 0 after the last frame (looping preserved)" do
    path = File.tempname("bugs11_media_wrap", ".png")
    # Short uniform-ish delays so the whole cycle plays quickly; infinite loop.
    write_apng_delays path, [30, 30, 30], num_plays: 0
    begin
      s = headless_window
      img = ProbeSixel.new file: path, parent: s, width: 4, height: 3
      img.play

      # Play well past one full cycle (3 frames * 30ms) and confirm it keeps
      # looping (still playing, index within range) rather than stalling.
      seen = Set(Int32).new
      60.times do
        seen << img.anim_index
        sleep 0.01.seconds
      end

      img.playing?.should be_true
      (0 <= img.anim_index < 3).should be_true
      # Over a full cycle every frame index is visited, incl. a wrap back to 0.
      seen.should contain 0
    ensure
      img.try &.stop
      s.try &.destroy
    end
  ensure
    File.delete?(path) if path
  end
end
