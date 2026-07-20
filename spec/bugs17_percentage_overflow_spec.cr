require "./spec_helper"

include Crysterm

# BUGS17 B17-05 — the percentage resolver clamped only the offset
# accumulator (BUGS14 W3), not the percentage side. `(against * pct).to_i`
# is a checked Float64->Int32 narrowing, so a huge percentage (or one long
# enough to saturate `pct` to Float64::INFINITY) overflowed Int32 and raised
# OverflowError in the render fiber. The product is now clamped to
# ±1_000_000_000.0 before `.to_i`, mirroring the existing offset clamp.

private def guard_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

describe "BUGS17 B17-05: resolve_percentage overflow guard" do
  it "huge string-percentage width/left render without OverflowError" do
    s = guard_screen
    Widget::Box.new parent: s, width: "9999999999%", left: "-9999999999%",
      height: 2
    s.repaint # Dim#resolve must not raise OverflowError
  end

  it "a ~320-digit percentage (Float64 infinity) renders without OverflowError" do
    s = guard_screen
    huge = "9" * 320
    Widget::Box.new parent: s, width: "#{huge}%", height: 2
    s.repaint # pct saturates to Float64::INFINITY; must still not raise
  end
end
