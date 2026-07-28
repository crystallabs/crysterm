require "./spec_helper"

include Crysterm

# Regression spec for BUGS18 B18-90:
#
# The B17-37 fix installed one-time Event::Hide/Event::Detached clock-stop
# hooks (plus a resume-on-render) for CSS `@keyframes` animations only
# (src/widget_animation.cr). Its two sibling self-driving clocks —
# `Effect::Animated` (src/widget/effect/animated.cr, driving Fire/Matrix/Spray/
# SineScroller/etc.) and `Widget#pulse` (src/widget_fade.cr) — kept ticking a
# full FrameClock (request_render every frame) forever while their widget was
# hidden or detached. This spec pins the mirrored fix: both drivers now
# install one-time Hide/Detached pause + Show/Attached resume hooks.

# Exposes the pulse-fade internals for assertions (`@fade`/`@pulse_paused` are
# private).
private class PulseProbe < Crysterm::Widget::Box
  def fade_clock
    @fade
  end

  def pulse_paused?
    @pulse_paused
  end
end

describe "BUGS18 B18-90 hidden/detached effect and pulse clocks stop ticking" do
  describe "Effect::Animated (Fire)" do
    it "stops the clock when the widget is hidden, and resumes on show" do
      s = headless_screen(20, 10)
      fire = Crysterm::Widget::Effect::Fire.new parent: s, top: 0, left: 0, width: 8, height: 4
      begin
        fire.start
        fire.running?.should be_true

        fire.hide
        fire.running?.should be_false

        # A stray Hide broadcast (e.g. from an ancestor's emit_descendants)
        # while already paused must stay a no-op.
        fire.emit Crysterm::Event::Hide
        fire.running?.should be_false

        fire.show
        fire.running?.should be_true
      ensure
        fire.stop
      end
    end

    it "stops the clock when the widget is detached, and resumes on re-attach" do
      s = headless_screen(20, 10)
      fire = Crysterm::Widget::Effect::Fire.new parent: s, top: 0, left: 0, width: 8, height: 4
      begin
        fire.start
        fire.running?.should be_true

        s.remove fire # emits Event::Detached
        fire.running?.should be_false

        s.append fire # re-attach, emits Event::Attached
        fire.running?.should be_true
      ensure
        fire.stop
      end
    end

    it "does not resume on show if #stop was called explicitly while hidden" do
      s = headless_screen(20, 10)
      fire = Crysterm::Widget::Effect::Fire.new parent: s, top: 0, left: 0, width: 8, height: 4
      begin
        fire.start
        fire.hide
        fire.running?.should be_false

        fire.stop # explicit stop while hidden must stick
        fire.show
        fire.running?.should be_false
      ensure
        fire.stop
      end
    end
  end

  describe "Widget#pulse" do
    it "stops the clock when the widget is hidden, and resumes on show" do
      s = headless_screen(20, 10)
      w = PulseProbe.new parent: s, top: 0, left: 0, width: 8, height: 4
      begin
        w.pulse
        clock1 = w.fade_clock
        clock1.should_not be_nil
        clock1.not_nil!.running?.should be_true

        w.hide
        w.fade_clock.not_nil!.running?.should be_false
        w.pulse_paused?.should be_true

        w.show
        w.fade_clock.not_nil!.running?.should be_true
        # Resuming reuses the same clock (phase-continuous), not a rebuilt one.
        w.fade_clock.should be clock1
      ensure
        w.stop_fade
      end
    end

    it "stops the clock when the widget is detached, and resumes on re-attach" do
      s = headless_screen(20, 10)
      w = PulseProbe.new parent: s, top: 0, left: 0, width: 8, height: 4
      begin
        w.pulse
        w.fade_clock.not_nil!.running?.should be_true

        s.remove w # emits Event::Detached
        w.fade_clock.not_nil!.running?.should be_false

        s.append w # re-attach, emits Event::Attached
        w.fade_clock.not_nil!.running?.should be_true
      ensure
        w.stop_fade
      end
    end
  end
end
