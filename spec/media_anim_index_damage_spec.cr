require "./spec_helper"

include Crysterm

# Regression spec: driving an animation by writing `anim_index` directly (an
# external clock after `#pause`, as in `tests/misc/netscape.cr`) must repaint
# under `OptimizationFlag::DamageTracking` (on by default).
#
# `anim_index=` is a supported way to drive playback, but the internal loops
# advance the frame *and* call `request_render` (which marks the widget dirty),
# whereas an external `anim_index =` used to be a plain property assignment. The
# selective damage composite only repaints widgets in the dirty set, so a
# fixed-size image whose only per-frame change was `anim_index=` was carried
# over stale and appeared frozen — animating only on the occasional full frame
# (resize, re-probe), i.e. "stops at random, resumes minutes later". The fix
# makes `anim_index=` mark the widget dirty when the index actually changes.

private def headless_screen(width : Int32? = nil, height : Int32? = nil,
                            optimization : Crysterm::OptimizationFlag = Crysterm::OptimizationFlag::None)
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: width, height: height, optimization: optimization, dock_borders: false)
end

# A cell-region signature (attr + char per cell) over a widget's painted
# rectangle, so two renders can be compared for "did the picture change".
private def region_sig(s : Crysterm::Window, img : Crysterm::Widget) : String
  lp = img.lpos.not_nil!
  String.build do |io|
    (lp.yi...lp.yl).each do |y|
      row = s.lines[y]? || next
      (lp.xi...lp.xl).each do |x|
        cell = row[x]? || next
        io << cell.attr << ':' << cell.char << ';'
      end
    end
  end
end

describe "Widget::Media::Base#anim_index= damage tracking" do
  it "marks the widget dirty only when the index actually changes" do
    s = headless_screen
    img = Crysterm::Widget::Media::Glyph.new parent: s, top: 0, left: 0, width: 4, height: 2

    img.anim_index = 0
    img.render_dirty = false

    # No-op write: same index, no dirty mark.
    img.anim_index = 0
    img.render_dirty?.should be_false

    # Real change: marks dirty so the damage composite repaints it.
    img.anim_index = 3
    img.render_dirty?.should be_true
    img.anim_index.should eq 3
  ensure
    img.try &.stop
    s.try &.destroy
  end

  it "repaints a paused, externally-clocked animation under DamageTracking" do
    gif = "data/image/netscape.gif"
    pending! "no animated test fixture" unless File.exists?(gif)

    # Small widget on a much larger screen, so the selective damage path engages
    # (a full-screen-sized widget would trip the cost-parity fall back to full,
    # which repaints everything and would hide the bug).
    s = headless_screen width: 60, height: 30, optimization: Crysterm::OptimizationFlag::DamageTracking

    img = Crysterm::Widget::Media::Glyph.new parent: s, top: 1, left: 1, width: 8, height: 4,
      file: gif, mode: Crysterm::Widget::Media::Glyph::Mode::Octant,
      fit: Crysterm::Widget::Media::Fit::Contain

    # Frames build in a background fiber; pump the scheduler until they're ready.
    img.play
    200.times do
      break if img.frames_ready?
      sleep 1.millisecond
    end
    img.frames_ready?.should be_true

    # Take over the clock ourselves, exactly like the netscape example.
    img.pause

    # Baseline full frame (the first frame under DamageTracking is always full).
    img.anim_index = 0
    s.repaint
    base = region_sig s, img

    # Drive later frames purely via `anim_index=` + a selective render. At least
    # one throbber frame must differ from frame 0 — before the fix these were all
    # carried over as `base` because the widget was never marked dirty.
    changed = (1..8).any? do |i|
      img.anim_index = i
      s.repaint
      region_sig(s, img) != base
    end
    changed.should be_true

    # The selective path must actually have been exercised (else the assertion
    # above would pass trivially via full frames).
    s.damage_fast_frames.should be > 0
  ensure
    img.try &.stop
    s.try &.destroy
  end
end
