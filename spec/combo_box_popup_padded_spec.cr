require "./spec_helper"

include Crysterm

# The combo drop-down is a *window-appended* child, so its `left`/`top` are
# relative to the window's content origin (`aleft == window.ileft + left`). On a
# padded/bordered window the placement must subtract the window inset, or the
# popup drifts right+down by the inset. Unpadded specs never caught this; these
# pin the corrected placement on a padded window (FORMAL-WIDGETS Part A Piece 3,
# `Overlay.place_child`).

private def cbp_screen(padding)
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    padding: padding,
    default_quit_keys: false)
end

private def cbp_combo(s, top)
  Crysterm::Widget::ComboBox.new parent: s, top: top, left: 5, width: 16, height: 1,
    options: ["Red", "Green", "Blue", "Cyan", "Magenta", "Maroon"]
end

describe "ComboBox popup placement on a padded window" do
  it "drops the list flush below the combo (no inset drift)" do
    s = cbp_screen 2
    cb = cbp_combo s, top: 5
    cb.focus
    s.render
    cb.show_popup
    pop = cb.popup_widget.not_nil!
    s.render

    # Absolute placement must track the combo exactly, regardless of the
    # window's 2-cell padding.
    pop.aleft.should eq cb.aleft
    pop.atop.should eq cb.atop + cb.aheight
  end

  it "keeps the flipped-above list flush to the combo on a padded window" do
    # Combo near the bottom so the list flips above; still must align on x and
    # butt against the combo's top on the padded window.
    s = cbp_screen 2
    cb = cbp_combo s, top: 17
    cb.focus
    s.render
    cb.show_popup
    pop = cb.popup_widget.not_nil!
    s.render

    pop.aleft.should eq cb.aleft
    pop.atop.should be < cb.atop
    (pop.atop + pop.aheight).should eq cb.atop
  end
end
