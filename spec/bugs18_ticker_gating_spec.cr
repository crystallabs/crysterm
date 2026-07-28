require "./spec_helper"

include Crysterm

# Regression spec for the BUGS18 B18-90 leftovers scoped out of
# spec/bugs18_effect_clock_spec.cr (which covers Effect::Animated and
# Widget#pulse): the same keep-ticking-while-hidden/detached defect existed
# in two more self-driving clocks —
#
#   * `Widget::Gradient`'s private `Timer` (`animate: true`,
#     src/widget/gradient.cr) — ticks `phase += speed` + `request_render`
#     forever.
#   * `Widget::Media::Base`'s animation frame clock (`#animate_loop`, driving
#     `#play`'d GIF/APNG playback, src/widget/media/base.cr) — ticks
#     `anim_index` + `request_render` forever.
#
# Both now install one-time Hide/Detached pause + Show/Attached resume hooks,
# mirroring the Effect::Animated/Widget#pulse convention exactly: a
# `@*_paused` flag records an auto-pause (so a later show/attach resumes it),
# while an explicit stop clears the flag (so it isn't silently resurrected by
# a later show). A *shared* `animate: <Timer>` clock is left alone in both
# cases — it belongs to the caller.

# Exposes the private pause flag for assertions.
private class GradientProbe < Crysterm::Widget::Gradient
  def paused?
    @gradient_paused
  end
end

# Exposes the private animation clock + pause flag for assertions.
private class MediaProbe < Crysterm::Widget::Media::Sixel
  def animation_clock : Crysterm::FrameClock?
    @animation
  end

  def playback_paused?
    @playback_paused
  end
end

# Builds an APNG with explicit per-frame delays (ms), mirroring
# spec/bugs11_media_animation_spec.cr's fixture idiom (no ffmpeg needed).
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

describe "BUGS18 B18-90 leftovers: Gradient/Media ticker gating" do
  describe "Widget::Gradient animate: true" do
    it "stops the private timer when hidden, and resumes on show" do
      s = headless_screen(20, 10)
      g = GradientProbe.new parent: s, top: 0, left: 0, width: 8, height: 3,
        animate: true, interval: 0.05.seconds
      begin
        g.timer.should_not be_nil
        g.timer.not_nil!.running?.should be_true

        g.hide
        g.timer.not_nil!.running?.should be_false
        g.paused?.should be_true

        # A stray Hide broadcast (e.g. from an ancestor's emit_descendants)
        # while already paused must stay a no-op.
        g.emit Crysterm::Event::Hide
        g.timer.not_nil!.running?.should be_false

        g.show
        s.repaint
        g.timer.not_nil!.running?.should be_true
        g.paused?.should be_false
      ensure
        g.stop_animation
      end
    end

    it "stops the timer when detached, and resumes on re-attach" do
      s = headless_screen(20, 10)
      g = GradientProbe.new parent: s, top: 0, left: 0, width: 8, height: 3, animate: true

      begin
        g.timer.not_nil!.running?.should be_true

        s.remove g # emits Event::Detached
        g.timer.not_nil!.running?.should be_false

        s.append g # re-attach, emits Event::Attached
        g.timer.not_nil!.running?.should be_true
      ensure
        g.stop_animation
      end
    end

    it "does not resume on show if #stop_animation was called explicitly while hidden" do
      s = headless_screen(20, 10)
      g = GradientProbe.new parent: s, top: 0, left: 0, width: 8, height: 3, animate: true

      begin
        g.hide
        g.timer.not_nil!.running?.should be_false
        g.paused?.should be_true

        g.stop_animation # explicit stop while hidden must stick
        g.paused?.should be_false

        g.show
        g.timer.not_nil!.running?.should be_false
      ensure
        g.stop_animation
      end
    end

    it "leaves a shared animate: Timer clock running when the widget hides" do
      s = headless_screen(20, 10)
      clock = Crysterm::Timer.new 0.05.seconds
      g = GradientProbe.new parent: s, top: 0, left: 0, width: 8, height: 3, animate: clock

      begin
        clock.running?.should be_true
        g.hide
        # The shared clock belongs to the caller — untouched by this widget's
        # visibility, and this widget never installs pause/resume hooks for it.
        clock.running?.should be_true
        g.paused?.should be_false
      ensure
        clock.stop
      end
    end
  end

  describe "Widget::Media::Base animation frame clock" do
    it "stops the clock when hidden, and resumes on show" do
      path = File.tempname("bugs18_ticker_media", ".png")
      write_apng_delays path, [20, 20, 20], num_plays: 0
      begin
        s = headless_screen(20, 10)
        img = MediaProbe.new file: path, parent: s, top: 0, left: 0, width: 4, height: 3
        img.play

        # Let the compose fiber build @src_frames and the clock's immediate
        # first tick fire.
        200.times do
          break if img.frames_ready? && img.animation_clock
          sleep 0.005.seconds
        end
        img.animation_clock.should_not be_nil
        img.playing?.should be_true

        img.hide
        img.playing?.should be_false
        img.animation_clock.not_nil!.running?.should be_false
        img.playback_paused?.should be_true

        # A stray Hide broadcast while already paused must stay a no-op.
        img.emit Crysterm::Event::Hide
        img.playing?.should be_false

        img.show
        img.playing?.should be_true
        img.playback_paused?.should be_false
        img.animation_clock.not_nil!.running?.should be_true
      ensure
        img.try &.stop
        s.try &.destroy
      end
    ensure
      File.delete?(path) if path
    end

    it "stops the clock when detached, and resumes on re-attach" do
      path = File.tempname("bugs18_ticker_media_detach", ".png")
      write_apng_delays path, [20, 20, 20], num_plays: 0
      begin
        s = headless_screen(20, 10)
        img = MediaProbe.new file: path, parent: s, top: 0, left: 0, width: 4, height: 3
        img.play

        200.times do
          break if img.frames_ready? && img.animation_clock
          sleep 0.005.seconds
        end
        img.playing?.should be_true

        s.remove img # emits Event::Detached
        img.playing?.should be_false
        img.animation_clock.not_nil!.running?.should be_false

        s.append img # re-attach, emits Event::Attached
        img.playing?.should be_true
        img.animation_clock.not_nil!.running?.should be_true
      ensure
        img.try &.stop
        s.try &.destroy
      end
    ensure
      File.delete?(path) if path
    end

    it "does not resume on show if #stop was called explicitly while hidden" do
      path = File.tempname("bugs18_ticker_media_stop", ".png")
      write_apng_delays path, [20, 20, 20], num_plays: 0
      begin
        s = headless_screen(20, 10)
        img = MediaProbe.new file: path, parent: s, top: 0, left: 0, width: 4, height: 3
        img.play

        200.times do
          break if img.frames_ready? && img.animation_clock
          sleep 0.005.seconds
        end
        img.playing?.should be_true

        img.hide
        img.playing?.should be_false
        img.playback_paused?.should be_true

        img.stop # explicit stop while hidden must stick
        img.playback_paused?.should be_false

        img.show
        img.playing?.should be_false
      ensure
        img.try &.stop
        s.try &.destroy
      end
    ensure
      File.delete?(path) if path
    end
  end
end
