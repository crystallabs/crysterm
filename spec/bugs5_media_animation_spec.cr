require "./spec_helper"

include Crysterm

# Regression specs for BUGS5 (media/animation/effects).
#
# BUG 1 — CSS `@keyframes` progress must be driven by real wall-clock elapsed
#   (`Time.instant - start_at`), not a fixed per-tick step, so dropped/late
#   frames don't make a finite animation run long or a looping one drift slow.
# BUG 2 — a URL-sourced Überzug image must not leak its fetched temp file/fd:
#   the file is tracked and deleted on reload / clear_image / teardown.
# BUG 3 — settable glyph/ramp/pool/color collections must guard against empty
#   values so the render fiber can't crash (IndexError / clamp ArgumentError /
#   division by zero).

private def headless_window(w = 12, h = 4)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h)
end

# --------------------------------------------------------------------------
# BUG 1: keyframe progress driven by real elapsed time
# --------------------------------------------------------------------------

describe "CSS @keyframes real-elapsed progress (BUGS5)" do
  it "interpolates a looping animation proportionally to wall-clock time" do
    s = headless_window 10, 3
    b = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 3
    b.add_css_class "grow"
    s.stylesheet = "@keyframes grow { from { opacity: 0.0; } to { opacity: 1.0; } } " \
                   ".grow { opacity: 0.0; animation: grow 0.4s linear infinite; }"
    s._render # starts the animation

    sleep 0.1.seconds # ~25% through the 0.4s linear cycle
    a1 = b.style.alpha.not_nil!
    (0.02 <= a1 <= 0.55).should be_true # elapsed-driven, roughly a quarter in

    sleep 0.2.seconds # ~75% through the cycle
    a2 = b.style.alpha.not_nil!
    (a2 > a1).should be_true # progress advanced with real time, not stalled
    (0.4 <= a2 <= 0.98).should be_true
  ensure
    s.try &.destroy
  end

  it "settles a finite (1-iteration) animation on its final frame" do
    s = headless_window 10, 3
    b = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 3
    b.add_css_class "once"
    s.stylesheet = "@keyframes go { from { opacity: 0.0; } to { opacity: 1.0; } } " \
                   ".once { opacity: 0.0; animation: go 0.15s linear 1; }"
    s._render
    sleep 0.4.seconds # well past the single iteration
    (b.style.alpha.not_nil! > 0.95).should be_true
  ensure
    s.try &.destroy
  end
end

# --------------------------------------------------------------------------
# BUG 2: Überzug URL temp-file lifecycle (spec'd without real network via a
# `fetch_bytes` seam so no HTTP is performed)
# --------------------------------------------------------------------------

# Overrides the network fetch with canned bytes so the temp-file tracking and
# cleanup can be exercised offline.
private class FakeUeberzug < Crysterm::Widget::Media::Ueberzug
  def fetch_bytes(file : String) : Bytes
    Bytes[137, 80, 78, 71, 13, 10, 26, 10] # a few arbitrary bytes
  end

  def current_tmp_path : String?
    tmp_path
  end
end

describe "Media::Ueberzug URL temp-file cleanup (BUGS5)" do
  it "creates a temp file for a URL and deletes it on clear_image" do
    s = headless_window
    img = FakeUeberzug.new parent: s, width: 4, height: 3
    img.load "http://example.com/pic.png"

    p = img.current_tmp_path
    p.should_not be_nil
    File.exists?(p.not_nil!).should be_true

    img.clear_image
    img.current_tmp_path.should be_nil
    File.exists?(p.not_nil!).should be_false
  ensure
    s.try &.destroy
  end

  it "deletes the previous temp file when a new URL is loaded" do
    s = headless_window
    img = FakeUeberzug.new parent: s, width: 4, height: 3
    img.load "http://example.com/a.png"
    first = img.current_tmp_path.not_nil!
    File.exists?(first).should be_true

    img.load "http://example.com/b.png"
    second = img.current_tmp_path.not_nil!
    second.should_not eq first
    File.exists?(first).should be_false # previous temp cleaned up
    File.exists?(second).should be_true

    img.clear_image
    File.exists?(second).should be_false
  ensure
    s.try &.destroy
  end

  it "leaves a local file path untouched (no temp file created)" do
    s = headless_window
    img = FakeUeberzug.new parent: s, width: 4, height: 3
    img.load "some/local/pic.png"
    img.current_tmp_path.should be_nil
  ensure
    s.try &.destroy
  end
end

# --------------------------------------------------------------------------
# BUG 3: effects reject empty settable collections (no render-fiber crash)
# --------------------------------------------------------------------------

describe "Effect empty-collection guards (BUGS5)" do
  it "Fire falls back to the default ramp when assigned an empty ramp" do
    s = headless_window 6, 6
    f = Widget::Effect::Fire.new ramp: [] of Char, parent: s, width: 6, height: 6
    f.ramp.should eq Widget::Effect::Fire::DEFAULT_RAMP

    f.ramp = [] of Char
    f.ramp.empty?.should be_false

    # A single-glyph ramp must not crash `#cell` (clamp(1, 0) would raise).
    f.ramp = ['x']
    f.resize 6, 6
    f.advance 6, 6
    6.times { |x| f.cell(x, 5, 6, 6) } # bottom row is the seeded hot row
  ensure
    s.try &.destroy
  end

  it "Matrix falls back to the default pool when assigned an empty pool" do
    s = headless_window 6, 6
    m = Widget::Effect::Matrix.new pool: [] of Char, parent: s, width: 6, height: 6
    m.pool.empty?.should be_false

    m.pool = [] of Char
    m.pool.should eq Widget::Effect::Matrix::DEFAULT_POOL

    # Advancing and sampling must not raise (`@pool.sample` on an empty pool).
    m.resize 6, 6
    m.advance 6, 6
    6.times { |y| 6.times { |x| m.cell(x, y, 6, 6) } }
  ensure
    s.try &.destroy
  end

  it "Spray guards pattern, grow and spark_colors against empties" do
    s = headless_window 6, 5
    sp = Widget::Effect::Spray.new(
      pattern: "   ", grow: [] of String, parent: s, width: 6, height: 5)
    sp.grow.empty?.should be_false # empty grow -> default

    sp.spark_colors = [] of Int32
    sp.spark_colors.empty?.should be_false # empty spark colors -> default (avoids % 0)

    # Whitespace-only pattern must still resolve to a fillable slot set and run
    # a frame without raising.
    sp.pattern = "   "
    sp.resize 6, 5
    sp.advance 6, 5
    5.times { |y| 6.times { |x| sp.cell(x, y, 6, 5) } }
  ensure
    s.try &.destroy
  end
end
