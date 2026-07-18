require "./spec_helper"

include Crysterm

# Wheeling over an OPEN combo drop-down must scroll through entries and keep
# the list open, not dismiss it.
#
# Regression was specific to an *editable* combo: it keeps keyboard focus while
# open, but the screen's wheel handling implicitly focuses the scrollable list
# under the pointer (`Window#dispatch_mouse` -> `focusable_at`), stealing focus
# from the combo and triggering its blur-closes-the-popup cleanup mid-wheel.
# Fix: exclude the popup from the wheel-focus path for editable combos
# (`#focus_on_click = false`) and ignore blur that merely moves into the popup.

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
    cb.show_popup
    pop = cb.popup_widget.not_nil!
    s.render

    cb.open?.should be_true
    before = pop.current_index

    # Wheel down: must scroll entries (selection moves forward) and stay open.
    cbw_wheel_over s, pop, 1
    cb.open?.should be_true
    pop.current_index.should be > before

    # Focus must remain on the editable combo, not get stolen by the list.
    s.focused.should eq cb
  end

  it "keeps a non-editable drop-down open and moves the selection on the wheel" do
    s = cbw_screen
    cb = cbw_combo s, editable: false
    cb.focus
    cb.show_popup
    pop = cb.popup_widget.not_nil!
    s.render

    cb.open?.should be_true
    before = pop.current_index

    cbw_wheel_over s, pop, 1
    cb.open?.should be_true
    pop.current_index.should be > before
  end
end
