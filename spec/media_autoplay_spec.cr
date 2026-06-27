require "./spec_helper"

include Crysterm

# Regression spec for `Widget::Media::Base#play`'s guard against animating a
# *single-frame* source.
#
# `#bitmap=` (the entry point `Graph::Canvas` uses to present each painted
# frame) wraps the bitmap as a `PNGGIF::PNG` built via the frame-list
# constructor, whose `frames` is ALWAYS non-nil — even for one frame (unlike a
# decoded still, where it stays nil). The in-band graphics backends'
# `#ensure_animation` plays any source with non-nil `frames`, so without the
# guard a still canvas on a Sixel/Kitty backend would start a one-frame loop
# that re-renders forever at the minimum interval (a CPU/redraw spin).

private def headless_screen
  Crysterm::Screen.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
end

private def solid_bitmap(w = 3, h = 2) : PNGGIF::Bitmap
  Array.new(h) { Array.new(w) { PNGGIF::Pixel.new(10, 20, 30, 255) } }
end

describe "Widget::Media::Base#play single-frame guard" do
  it "does not start playback for a bitmap-injected (single-frame) source" do
    s = headless_screen
    img = Crysterm::Widget::Media::Sixel.new parent: s
    img.bitmap = solid_bitmap

    img.playing?.should be_false
    img.play # auto-play path would spin a one-frame loop without the guard
    img.playing?.should be_false
    img.frames_ready?.should be_false
  ensure
    img.try &.stop
    s.try &.destroy
  end

  it "still plays a genuinely multi-frame (animated) source" do
    # Positive control: a real animated GIF has >1 frame, so `#play` must engage.
    gif = "data/image/netscape.gif"
    pending! "no animated test fixture" unless File.exists?(gif)
    s = headless_screen
    img = Crysterm::Widget::Media::Sixel.new file: gif, parent: s
    img.play
    img.playing?.should be_true
  ensure
    img.try &.stop # halt the playback fiber before teardown
    s.try &.destroy
  end
end
