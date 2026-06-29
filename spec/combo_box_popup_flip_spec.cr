require "./spec_helper"

include Crysterm

# A combo near the bottom of the screen used to drop its list *below* itself
# regardless of room, so the list spilled past the last row and looked like it
# never opened (only its top border/first row showed). Qt opens a `QComboBox`
# upward in that case. `ComboBox#place_popup` now flips the drop-down above the
# combo when its full height would not fit below but fits above — and the popup
# re-runs the placement at render, against the combo's final (themed) geometry.

private def cbf_screen(height)
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: height,
    default_quit_keys: false)
end

private def cbf_combo(s, top)
  Crysterm::Widget::ComboBox.new parent: s, top: top, left: 5, width: 16, height: 1,
    options: ["Red", "Green", "Blue", "Cyan", "Magenta", "Maroon"]
end

describe "ComboBox popup vertical placement" do
  it "flips the drop-down above the combo when it would overflow off the bottom" do
    # A 14-row screen with the combo near the bottom: its 8-row popup cannot fit
    # in the few rows below, so it must open upward and stay fully on-screen.
    s = cbf_screen 14
    cb = cbf_combo s, top: 11
    cb.focus
    s.render
    cb.open
    pop = cb.popup_widget.not_nil!
    s.render

    pop.atop.should be < cb.atop                    # opened above, not below
    pop.atop.should be >= 0                         # not clipped at the top
    (pop.atop + pop.aheight).should be <= s.aheight # nor off the bottom
  end

  it "opens the drop-down directly below the combo when there is room" do
    s = cbf_screen 24
    cb = cbf_combo s, top: 5
    cb.focus
    s.render
    cb.open
    pop = cb.popup_widget.not_nil!
    s.render

    pop.atop.should eq cb.atop + cb.aheight
  end
end
