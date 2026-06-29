require "./spec_helper"

include Crysterm

private def headless_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
end

# `Window#delete_bottom(top, bottom)` clears the single row `bottom`. It was a
# no-op: `clear_region`/`fill_region` are half-open in `y` (`yi.upto(yl - 1)`),
# so `clear_region(0, awidth, bottom, bottom)` iterated zero rows and the bottom
# row was never cleared. The far edge must be `bottom + 1`.
describe "Window#delete_bottom" do
  it "clears exactly the bottom row (was a no-op)" do
    s = headless_screen
    w = s.awidth
    h = s.aheight
    bottom = h - 1

    # Dirty the bottom row and one row above it, with a non-default attr/char.
    s.fill_region 7_i64, 'X', 0, w, bottom - 1, bottom + 1, override: true
    s.lines[bottom][0].char.should eq 'X'
    s.lines[bottom - 1][0].char.should eq 'X'

    s.delete_bottom 0, bottom

    # The bottom row is now cleared to the screen default…
    s.lines[bottom][0].char.should eq ' '
    s.lines[bottom][w - 1].char.should eq ' '
    s.lines[bottom][0].attr.should eq s.default_attr
    # …and only that row: the row above is untouched.
    s.lines[bottom - 1][0].char.should eq 'X'
    s.lines[bottom - 1][0].attr.should eq 7_i64
  end
end
