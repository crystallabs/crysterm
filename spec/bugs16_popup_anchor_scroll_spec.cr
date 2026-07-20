require "./spec_helper"

include Crysterm

# BUGS16 B16-31: ComboBox#place_popup (and DateEdit#position_popup for its
# calendar) anchored the pop-up on the owner's *layout* coords
# (`{aleft, atop, ...}`). Inside a scrolled/`child_base` ancestor the owner is
# painted `base` rows above its layout position (Widget#coords subtracts
# `scrollable_parent_lpos.base`), while the pop-up — a window-appended child —
# is painted exactly where `Overlay.place_child` puts it. So the drop-down
# opened detached from the visible combo, over unrelated widgets. Both now
# anchor on the *painted* rect (`last_rendered_position?`), mirroring
# Menu#open_submenu.

private def pas_screen(w = 80, h = 24)
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: w, height: h,
    default_quit_keys: false)
end

describe "BUGS16 B16-31: pop-up anchoring inside a scrolled container" do
  it "opens the ComboBox drop-down below the PAINTED combo, not its layout row" do
    s = pas_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 40, height: 6,
      scrollable: true
    cb = Widget::ComboBox.new parent: box, top: 8, left: 2, width: 16, height: 1,
      options: ["Red", "Green", "Blue", "Cyan"]
    # A child far below the combo gives the box a real scroll extent.
    Widget::Box.new parent: box, top: 20, left: 0, width: 4, height: 1
    s._render

    box.scroll_to 4, true
    s._render

    lp = cb.lpos.not_nil!
    # The combo is painted 4 rows above its layout position.
    lp.yi.should_not eq cb.atop
    lp.yi.should eq cb.atop - 4

    cb.show_popup
    pop = cb.popup_widget.not_nil!
    s._render

    # Anchored on the painted combo (row 4), not the layout row (8).
    pop.atop.should eq lp.yi + cb.aheight
    pop.atop.should_not eq cb.atop + cb.aheight
  end

  it "keeps unscrolled placement directly below the combo (no regression)" do
    s = pas_screen
    cb = Widget::ComboBox.new parent: s, top: 5, left: 5, width: 16, height: 1,
      options: ["Red", "Green", "Blue", "Cyan"]
    cb.focus
    s._render
    cb.show_popup
    pop = cb.popup_widget.not_nil!
    s._render

    pop.atop.should eq cb.atop + cb.aheight
    cb.lpos.not_nil!.yi.should eq cb.atop # not scrolled: painted == layout
  end

  it "opens the DateEdit calendar against the PAINTED field inside a scroll" do
    s = pas_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 40, height: 6,
      scrollable: true
    de = Widget::DateEdit.new parent: box, top: 8, left: 2, width: 12, height: 1,
      date: Time.utc(2026, 7, 4)
    Widget::Box.new parent: box, top: 20, left: 0, width: 4, height: 1
    s._render

    box.scroll_to 4, true
    s._render

    lp = de.lpos.not_nil!
    lp.yi.should eq de.atop - 4

    de.show_popup
    pop = de.@popup.not_nil!
    s._render

    # The calendar opens directly below the painted field (it fits below on a
    # 24-row screen), not below the layout row 8.
    pop.atop.should eq lp.yi + de.aheight
    pop.atop.should_not eq de.atop + de.aheight
  end
end
