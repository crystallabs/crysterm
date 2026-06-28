require "./spec_helper"

include Crysterm

private def headless_screen
  Crysterm::Screen.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
end

# Locks `Mixin::PagedContainer#previous_index`'s handling of the `-1`
# "no page selected" sentinel. `#current_page` already guards `-1` (see
# `widget_tab_switch_spec.cr`); `#previous_index` must too — `(−1 − 1) % size`
# maps to `size − 2`, skipping the last page rather than wrapping to it.
describe Crysterm::Mixin::PagedContainer do
  it "wraps to the last page when stepping back from the unselected (-1) state" do
    s = headless_screen
    sw = Widget::StackedWidget.new parent: s, left: 0, top: 0, width: 20, height: 6

    # Populate pages without selecting one, reaching the `-1` sentinel with
    # pages present (the state `#current_page`'s guard is written for).
    3.times { sw.pages << Widget::Box.new(parent: sw) }
    sw.current_index.should eq -1

    sw.previous_page
    # Must land on the last page (index 2), not `(-1 - 1) % 3 == 1`.
    sw.current_index.should eq 2
  end
end
