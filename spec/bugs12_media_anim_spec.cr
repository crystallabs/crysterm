require "./spec_helper"

include Crysterm

# Regression specs for the BUGS12 media/animation/frame-clock batch:
#
# * #11 — `Media::Base#bitmap=` must stop in-progress playback before swapping
#   the source (a zombie `FrameClock`/streaming decoder otherwise survives).
# * #20 — `background-size` changes take effect after the background layer
#   exists (`update_background_media` re-asserts `fit`, invalidating cache).
# * #18 — the CSS keyframe progress calc uses float modulo, so an infinite
#   animation whose cycle count exceeds `Int32::MAX` doesn't raise `OverflowError`.
# * #7  — `FrameClock#start` stores the fiber before enqueueing (functional
#   regression: the clock still ticks and stops cleanly).

private def headless_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 80, height: 24)
end

private def solid_bitmap(r = 10, g = 20, b = 30, w = 4, h = 4) : PNGGIF::Bitmap
  Array.new(h) { Array.new(w) { PNGGIF::Pixel.new(r, g, b, 255) } }
end

# Subclass exposing the protected keyframe progress helper for #18.
private class FracProbe < Crysterm::Widget::Box
  def probe(cycles : Float64, alt : Bool) : Float64
    keyframe_cycle_frac(cycles, alt)
  end
end

describe "BUGS12 #11 Media::Base#bitmap= stops playback" do
  it "stops an in-progress animation before swapping in a still bitmap" do
    gif = "#{__DIR__}/../data/image/netscape.gif"
    pending! "no animated test fixture" unless File.exists?(gif)
    s = headless_screen
    img = Crysterm::Widget::Media::Sixel.new file: gif, parent: s
    img.play
    img.playing?.should be_true

    # Replacing the source must stop the (now dead) animation; without the
    # `stop` the FrameClock keeps advancing at the old GIF's frame rate.
    img.bitmap = solid_bitmap
    img.playing?.should be_false
    img.anim_index.should eq 0
    # The single-frame slot from the previous animation is dropped.
    img.frames_ready?.should be_false
  ensure
    img.try &.stop
    s.try &.destroy
  end

  it "is a safe no-op for a never-playing single-frame device" do
    s = headless_screen
    img = Crysterm::Widget::Media::Sixel.new parent: s
    img.playing?.should be_false
    img.bitmap = solid_bitmap # must not raise
    img.playing?.should be_false
  ensure
    img.try &.stop
    s.try &.destroy
  end
end

describe "BUGS12 #20 background-size re-asserted after layer exists" do
  it "updates the background layer's fit when style.background_size changes" do
    orig = Crysterm::Config.media_exclude
    Crysterm::Config.media_exclude = "kitty" # force the cell-grid backend
    begin
      s = headless_screen
      box = Widget::Box.new parent: s, top: 0, left: 0, width: 12, height: 6
      box.style.background_image = "#{__DIR__}/../data/image/matterhorn.png"
      box.style.background_size = Style::BackgroundSize::Contain
      s.repaint

      bg = box.background_media
      bg.should_not be_nil
      bg.not_nil!.fit.should eq Widget::Media::Fit::Contain

      # Change the size after the layer exists; the per-frame reconcile must
      # re-assert it (previously ignored — fit was set once at creation).
      box.style.background_size = Style::BackgroundSize::Cover
      box.repaint
      box.background_media.not_nil!.fit.should eq Widget::Media::Fit::Cover
    ensure
      Crysterm::Config.media_exclude = orig
    end
  end
end

describe "BUGS12 #20 Media::Base#fit=" do
  it "changes the fit and returns the new value" do
    s = headless_screen
    img = Crysterm::Widget::Media::Sixel.new parent: s
    img.fit = Widget::Media::Fit::Cover
    img.fit.should eq Widget::Media::Fit::Cover
    (img.fit = Widget::Media::Fit::Contain).should eq Widget::Media::Fit::Contain
    img.fit.should eq Widget::Media::Fit::Contain
  ensure
    img.try &.stop
    s.try &.destroy
  end
end

describe "BUGS12 #18 keyframe progress float modulo" do
  it "does not raise OverflowError for cycle counts past Int32::MAX" do
    probe = FracProbe.new
    huge = (Int32::MAX.to_f64) * 1000.0 + 0.25
    frac = probe.probe(huge, false)
    frac.should be >= 0.0
    frac.should be <= 1.0
  end

  it "matches the old integer-based fraction for small cycle counts" do
    probe = FracProbe.new
    # Forward direction: fraction is just the cycle remainder.
    probe.probe(2.25, false).should be_close(0.25, 1e-9)
    probe.probe(0.75, false).should be_close(0.75, 1e-9)
  end

  it "reverses direction on an odd integer part when alternating" do
    probe = FracProbe.new
    # Even integer part (2): forward.
    probe.probe(2.25, true).should be_close(0.25, 1e-9)
    # Odd integer part (3): reversed (1 - frac).
    probe.probe(3.25, true).should be_close(0.75, 1e-9)
  end

  it "stays in [0,1] and alternates correctly for a huge alternating cycle count" do
    probe = FracProbe.new
    huge = (Int32::MAX.to_f64) * 2.0 # large, even parity path exercised
    frac = probe.probe(huge + 0.4, true)
    frac.should be >= 0.0
    frac.should be <= 1.0
  end
end

describe "BUGS12 #7 FrameClock#start stores the fiber" do
  it "still ticks after start and stops cleanly (fiber enqueued correctly)" do
    ticks = 0
    stops = 0
    clock = Crysterm::FrameClock.new(1.millisecond) { ticks += 1 }
    clock.on_stop { stops += 1 }

    clock.start
    clock.running?.should be_true
    sleep 30.milliseconds
    ticks.should be > 0

    clock.stop
    sleep 20.milliseconds
    clock.running?.should be_false
    stops.should eq 1
  end
end
