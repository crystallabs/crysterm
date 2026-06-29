require "./spec_helper"

include Crysterm

# Wheeling over an OPEN combo drop-down must scroll/move through the entries and
# keep the list open — it must NOT dismiss it.
#
# The regression was specific to an *editable* combo: it keeps keyboard focus
# while open (so typing keeps filtering), but the screen's wheel handling
# implicitly focuses the scrollable list under the pointer
# (`Window#dispatch_mouse` → `focusable_at`). That stole focus from the combo,
# and the combo's blur-closes-the-popup tidy-up then dismissed the drop-down
# mid-wheel. The fix keeps the popup off the wheel-focus path for editable
# combos (`#focus_on_click = false`) and hardens the blur handler to ignore a
# focus that merely moved *into* the popup.

private def cbw_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

private def cbw_combo(s, editable)
  Crysterm::Widget::ComboBox.new parent: s, top: 5, left: 5, width: 16, height: 1,
    editable: editable, options: ["Red", "Green", "Blue", "Cyan", "Magenta", "Maroon"]
end

private def cbw_wheel_over(s, pop, row)
  # Item boxes are hit-tested by their unscrolled geometry from the content top.
  s.dispatch_mouse ::Tput::Mouse::Event.new(
    ::Tput::Mouse::Action::WheelDown, ::Tput::Mouse::Button::None,
    pop.aleft + 2, pop.atop + pop.itop + row)
end

describe "ComboBox popup wheel scrolling" do
  it "keeps an editable drop-down open and moves the selection on the wheel" do
    s = cbw_screen
    cb = cbw_combo s, editable: true
    cb.focus
    cb.open
    pop = cb.popup_widget.not_nil!
    s.render

    cb.open?.should be_true
    before = pop.selected

    # Wheel down over the list: it must scroll the entries (selection moves
    # forward) AND stay open — not close without selecting anything.
    cbw_wheel_over s, pop, 1
    cb.open?.should be_true
    pop.selected.should be > before

    # And focus must remain on the editable combo (so typing keeps filtering),
    # not get stolen by the list.
    s.focused.should eq cb
  end

  it "keeps a non-editable drop-down open and moves the selection on the wheel" do
    s = cbw_screen
    cb = cbw_combo s, editable: false
    cb.focus
    cb.open
    pop = cb.popup_widget.not_nil!
    s.render

    cb.open?.should be_true
    before = pop.selected

    cbw_wheel_over s, pop, 1
    cb.open?.should be_true
    pop.selected.should be > before
  end
end
