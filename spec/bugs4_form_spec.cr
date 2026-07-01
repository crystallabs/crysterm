require "./spec_helper"

include Crysterm

# Regression specs for the BUGS4 form / spin-box fixes:
#
#  1. `Form#offset_focusable` used a hardcoded `-1` start sentinel for *both*
#     directions. That is only correct for a forward step (`(-1 + 1) % n == 0` →
#     first field); for a backward step it computed `(-1 - 1) % n == n - 2`, so
#     `#focus_last` (and the first-ever `Shift+Tab`, before anything is
#     selected) landed on the *second-to-last* field. The sentinel is now
#     direction-aware.

private def form_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

describe "BUGS4 Form focus wrap-around (fix #1)" do
  it "#previous_focusable with no selection returns the LAST field, not the second-to-last" do
    s = form_screen
    form = Crysterm::Widget::Form.new(parent: s, keys: true)
    fields = (0...5).map do |i|
      Crysterm::Widget::Box.new(parent: form, keys: true, top: i, left: 0, width: 5, height: 1)
    end
    s.render

    list = form.focusable
    list.size.should eq 5
    list.last.should eq fields.last

    # Nothing selected yet: a backward step must wrap to the last field (was the
    # second-to-last before the fix).
    form.selected = nil
    form.previous_focusable.should eq fields.last
  end

  it "#next_focusable with no selection still returns the FIRST field (no regression)" do
    s = form_screen
    form = Crysterm::Widget::Form.new(parent: s, keys: true)
    fields = (0...5).map do |i|
      Crysterm::Widget::Box.new(parent: form, keys: true, top: i, left: 0, width: 5, height: 1)
    end
    s.render

    form.selected = nil
    form.next_focusable.should eq fields.first
  end

  it "#focus_last focuses the last focusable field" do
    s = form_screen
    form = Crysterm::Widget::Form.new(parent: s, keys: true)
    fields = (0...4).map do |i|
      Crysterm::Widget::Box.new(parent: form, keys: true, top: i, left: 0, width: 5, height: 1)
    end
    s.render

    form.focus_last
    form.selected.should eq fields.last
  end
end
