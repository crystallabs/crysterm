require "./spec_helper"

include Crysterm

# Regression spec for BUGS17 B17-37:
#
# An infinite CSS `@keyframes` animation on a widget drives a ~30fps
# `FrameClock` that calls `request_render` every tick. When the widget is
# hidden it is skipped from rendering (its `coords` is nil), so
# `ensure_css_animation` stops being called and nothing stopped the clock —
# it kept ticking a full-window render loop forever. The fix installs a
# one-time `Event::Hide`/`Event::Detached` hook that stops the clock, WITHOUT
# marking the animation finished, so it resumes on the next render after
# `show`/re-attach.

private def headless_screen(w = 80, h = 24)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

# Exposes the CSS-animation internals for assertions.
private class AnimProbe < Crysterm::Widget::Box
  def anim_clock
    @css_animation
  end

  def stop_anim
    stop_css_animation
  end
end

private ANIM_CSS = <<-CSS
  .anim { animation: spin 1s infinite; }
  @keyframes spin { from { opacity: 0.1; } to { opacity: 0.9; } }
  CSS

describe "BUGS17 B17-37 hidden CSS animation stops its FrameClock" do
  it "stops the clock when the widget is hidden, and resumes on show" do
    screen = headless_screen
    box = AnimProbe.new parent: screen, width: 5, height: 3
    box.add_css_class "anim"
    begin
      screen.stylesheet = ANIM_CSS
      screen._render
      clock1 = box.anim_clock
      clock1.should_not be_nil
      clock1.not_nil!.running?.should be_true

      # Hiding must stop the clock so the ~30fps render loop ends.
      box.hide
      box.anim_clock.not_nil!.running?.should be_false
      # The animation was NOT marked finished — a further render while hidden
      # must not restart it (the widget's `coords` is nil, so `_render`
      # early-returns before `ensure_css_animation` anyway).
      screen._render
      box.anim_clock.not_nil!.running?.should be_false

      # Showing + rendering resumes the animation via the resume branch.
      box.show
      screen._render
      clock2 = box.anim_clock
      clock2.should_not be_nil
      clock2.not_nil!.running?.should be_true
    ensure
      box.try &.stop_anim
    end
  end

  it "stops the clock when the widget is detached, and resumes on re-attach" do
    screen = headless_screen
    box = AnimProbe.new parent: screen, width: 5, height: 3
    box.add_css_class "anim"
    begin
      screen.stylesheet = ANIM_CSS
      screen._render
      box.anim_clock.not_nil!.running?.should be_true

      screen.remove box # emits Event::Detached
      box.anim_clock.not_nil!.running?.should be_false

      screen.append box # re-attach
      screen._render
      box.anim_clock.not_nil!.running?.should be_true
    ensure
      box.try &.stop_anim
    end
  end
end
