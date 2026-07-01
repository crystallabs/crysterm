require "./spec_helper"

include Crysterm

# Regression spec for `Widget::Media::Tek`'s animation-loop supersession.
#
# The Tek window is driven by a private fiber (`#animate_loop`), not by the
# render-driven `Media::Base` framework. A parameter setter (`#level=`,
# `#dither=`, `#invert=`, `#fit=`) — and `#load` — call `#redraw!`, which only
# flips `@playing` false and lets the next render spawn a fresh loop. The old
# loop is asleep at that point, so when `#start_drawing` flips `@playing` back
# true and spawns the new loop, the old one would wake to `while @playing`
# still true and run concurrently, both fighting over the single Tek window.
#
# Fix: each loop gets a generation token (`@anim_gen`, bumped on every
# (re)start); a loop exits once its generation is no longer current. This spec
# asserts a re-draw while animating issues a NEW generation, so the previous
# loop detects staleness and exits instead of running alongside the new one.

private def headless_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
end

describe "Widget::Media::Tek animation supersession" do
  it "issues a new generation on re-draw so a superseded loop exits" do
    gif = "data/image/netscape.gif"
    pending! "no animated test fixture" unless File.exists?(gif)

    s = headless_screen
    tek = Crysterm::Widget::Media::Tek.new file: gif, parent: s

    tek.draw_tek # starts the animation loop (idempotent via @drawn)
    tek.playing?.should be_true
    gen1 = tek.anim_gen
    gen1.should be > 0

    # A parameter change while animating must restart playback under a *new*
    # generation, so the loop spawned for gen1 sees itself as stale and stops.
    tek.invert = true # -> redraw! (clears @drawn, stops @playing)
    tek.draw_tek      # next "render": spawns the replacement loop

    tek.playing?.should be_true
    tek.anim_gen.should be > gen1
  ensure
    tek.try &.stop # halt the playback fiber before teardown
    s.try &.destroy
  end
end
