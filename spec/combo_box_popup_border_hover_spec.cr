require "./spec_helper"

include Crysterm

# Two regressions in `Widget::ComboBox`'s drop-down:
#
#   1. `#position_popup` sized the popup with a hardcoded `+ 2` ("+ border"),
#      assuming exactly a 1-cell border on each side. A themed/borderless popup
#      then got phantom blank rows (or was clipped). Size must come from the
#      popup's real interior insets (`#ivertical`), like `Widget::Menu`, so it fits
#      for any border (0-cell, 1-cell, asymmetric).
#
#   2. The drop-down list never enabled `#hover_select`, so moving the mouse over
#      an entry did nothing. It must highlight the entry under the pointer, like
#      the `Completer` popup and a desktop combo box.

private def cbph_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

describe "ComboBox popup border sizing" do
  it "fits the visible rows for ANY border, deriving from ivertical not a hardcoded +2" do
    s = cbph_screen
    # Borderless, padding-less drop-down: interior insets are 0, so a hardcoded
    # `+ 2` would over-size it by two phantom rows.
    s.stylesheet = ".popup { border: none; padding: 0; }"
    s.apply_stylesheet

    cb = Crysterm::Widget::ComboBox.new parent: s, width: 12,
      options: ["red", "green", "blue"]
    cb.open
    pop = cb.popup_widget.not_nil!
    s.apply_stylesheet # cascade the freshly-created popup -> `.popup` (borderless)
    pop.render         # per-frame refit (`Popup#render` re-fits height to resolved border)

    # Borderless: no interior insets, so outer height is exactly 3 rows (not
    # 3 + 2) — proves the size tracks the popup's actual border.
    pop.ivertical.should eq 0
    pop.height.should eq 3

    # And in general the height is always rows + the popup's real ivertical.
    rows = Math.min(3, cb.max_visible_items)
    pop.height.should eq rows + pop.ivertical
  end

  it "still sizes a default 1-cell-border popup as rows + 2 (visually identical)" do
    s = cbph_screen
    cb = Crysterm::Widget::ComboBox.new parent: s, width: 12,
      options: ["red", "green", "blue"]
    cb.open
    pop = cb.popup_widget.not_nil!
    # Floor border = 1 cell each side -> ivertical 2 -> height 3 + 2, unchanged.
    pop.ivertical.should eq 2
    pop.height.should eq 5
  end
end

describe "ComboBox popup hover-select" do
  it "highlights the entry under the pointer on mouse-move" do
    s = cbph_screen
    cb = Crysterm::Widget::ComboBox.new parent: s, top: 1, left: 1, width: 12,
      options: ["red", "green", "blue"], selected: 0
    cb.open
    pop = cb.popup_widget.not_nil!
    s.render

    pop.hover_select?.should be_true
    pop.selected.should eq 0

    # Move the pointer onto the third row ("blue"): it must become selected with
    # no click, matching keyboard nav and the Completer's hover behavior.
    content_top = pop.atop + pop.itop
    x = pop.aleft + 2
    s.dispatch_mouse ::Tput::Mouse::Event.new(
      ::Tput::Mouse::Action::Move, ::Tput::Mouse::Button::None, x, content_top + 2)

    pop.selected.should eq 2
    pop.value.should eq "blue"
  end
end
