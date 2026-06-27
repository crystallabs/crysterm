require "./spec_helper"

include Crysterm

# Region clamping for the text `#dump` / image `#capture` entry points
# (`src/screen_capture.cr`). Driven headlessly over in-memory IOs.

private def capture_screen
  Crysterm::Screen.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
end

describe "Screen#dump region clamping" do
  it "dumps a normal in-bounds region" do
    s = capture_screen
    text = s.dump(0, 4, 0, 2)
    text.should_not be_nil
    text.not_nil!.should contain("w=4 h=2")
  end

  # Regression: an inverted region (xl < xi / yl < yi) — reachable via e.g.
  # `Widget#dump(dxl: <large negative>)` — used to reach `Dump.text` with a
  # negative width/height and crash on `"-" * w` ("Negative argument") or
  # `Array.new(h)`. It must instead clamp to an empty region.
  it "collapses an inverted x region to empty instead of crashing" do
    s = capture_screen
    text = s.dump(40, 10, 0, 2) # xi=40 > xl=10
    text.not_nil!.should contain("w=0")
  end

  it "collapses an inverted y region to empty instead of crashing" do
    s = capture_screen
    text = s.dump(0, 4, 20, 5) # yi=20 > yl=5
    text.not_nil!.should contain("h=0")
  end

  it "clamps an origin past the screen to an empty region" do
    s = capture_screen # 80x24
    text = s.dump(200, 300, 100, 200)
    text.not_nil!.should contain("w=0")
    text.not_nil!.should contain("h=0")
  end
end
