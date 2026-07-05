require "./spec_helper"

include Crysterm

# `Window#capture` and `Window#dump` share `#clamp_capture_region`, which
# collapses an inverted or fully out-of-range region to empty so neither
# entry point crashes on it (reachable via `Widget#capture`/`Widget#dump`,
# e.g. `include_decorations: false` on a widget narrower than its insets, or a
# large negative `d*` delta). `#dump` already returned an empty result; `#capture`
# used to reach `Capture.render` and raise `ArgumentError("empty region")`.
private def capture_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new,
    error: IO::Memory.new, width: 10, height: 4)
end

describe "Window#capture empty region" do
  it "returns nil for an inverted x region instead of raising" do
    s = capture_screen
    # xi=6 > xl=2 -> clamps to empty. Must not raise from Capture.render.
    s.capture(6, 2, 0, 3).should be_nil
  end

  it "returns nil for an inverted y region instead of raising" do
    s = capture_screen
    s.capture(0, 4, 3, 1).should be_nil # yi=3 > yl=1
  end

  it "returns nil for an origin past the screen instead of raising" do
    s = capture_screen
    s.capture(50, 60, 20, 30).should be_nil
  end

  it "still captures a valid in-bounds region" do
    s = capture_screen
    data = s.capture(0, 4, 0, 2)
    data.should_not be_nil
    # PNG magic bytes, so it really produced an image.
    d = data.not_nil!
    d[0].should eq 0x89_u8
    d[1].should eq 'P'.ord.to_u8
  end
end
