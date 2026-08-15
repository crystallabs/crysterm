require "./spec_helper"

include Crysterm

class Crysterm::Window
  # Spec-only access to the protected CSR scroll primitive (§1.3 made the
  # `scroll_*` drawing internals protected).
  def _spec_scroll_clear_bottom_row(top, bottom)
    scroll_clear_bottom_row top, bottom
  end
end

# `Window#scroll_clear_bottom_row(top, bottom)` (ex-`delete_bottom`) clears
# row `bottom`. Was a no-op:
# `clear_region`/`fill_region` are half-open in `y` (`yi.upto(yl - 1)`), so
# `clear_region(0, awidth, bottom, bottom)` iterated zero rows. Far edge must be
# `bottom + 1`.
describe "Window#scroll_clear_bottom_row" do
  it "clears exactly the bottom row (was a no-op)" do
    s = headless_screen(default_quit_keys: true)
    w = s.awidth
    h = s.aheight
    bottom = h - 1

    # Dirty the bottom row and the row above it, with a non-default attr/char.
    s.fill_region 7_i64, 'X', 0, w, bottom - 1, bottom + 1, force: true
    s.cell_rows[bottom][0].char.should eq 'X'
    s.cell_rows[bottom - 1][0].char.should eq 'X'

    s._spec_scroll_clear_bottom_row 0, bottom

    # Bottom row cleared to the screen default...
    s.cell_rows[bottom][0].char.should eq ' '
    s.cell_rows[bottom][w - 1].char.should eq ' '
    s.cell_rows[bottom][0].attr.should eq s.default_attr
    # ...and only that row: the row above is untouched.
    s.cell_rows[bottom - 1][0].char.should eq 'X'
    s.cell_rows[bottom - 1][0].attr.should eq 7_i64
  end
end
