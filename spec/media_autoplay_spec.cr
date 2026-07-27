require "./spec_helper"

include Crysterm

# Regression spec for `Widget::Media::Base#play`'s guard against animating a
# single-frame source.
#
# `#bitmap=` (used by `Graph::Canvas` to present each painted frame) wraps the
# bitmap as a `PNGGIF::PNG` via the frame-list constructor, whose `frames` is
# always non-nil — even for one frame (unlike a decoded still, where it stays
# nil). The in-band backends' `#ensure_animation` plays any source with
# non-nil `frames`, so without the guard a still canvas on Sixel/Kitty would
# spin a one-frame render loop forever.

describe "Widget::Media::Base#play single-frame guard" do
  it "does not start playback for a bitmap-injected (single-frame) source" do
    s = headless_screen(default_quit_keys: true)
    img = Crysterm::Widget::Media::Sixel.new parent: s
    img.bitmap = solid_bitmap(3, 2)

    img.playing?.should be_false
    img.play # would spin a one-frame loop without the guard
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
    s = headless_screen(default_quit_keys: true)
    img = Crysterm::Widget::Media::Sixel.new file: gif, parent: s
    img.play
    img.playing?.should be_true
  ensure
    img.try &.stop
    s.try &.destroy
  end
end
