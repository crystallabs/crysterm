require "./spec_helper"

include Crysterm

# An editable `ComboBox` sizes its drop-down to the match count (see
# `#position_popup`: height = min(matches, max_visible) + border). The *first*
# typed character opens the popup and sizes it, but every subsequent keystroke
# only routed through `#refresh_popup`, which used to refresh the rows without
# re-sizing — so the popup kept its initial height: too tall (blank rows) once
# the filter narrowed, or too short (scrolling) once a Backspace widened it.
# `#refresh_popup` must re-run `#position_popup` so the height tracks the filter.

private def combo_mem_screen
  Crysterm::Screen.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

private def cb_key(ch : Char)
  Crysterm::Event::KeyPress.new ch, nil
end

describe "ComboBox editable popup resize" do
  it "resizes the drop-down as the filter narrows and widens" do
    s = combo_mem_screen
    # Six options match 'a' (== default max_visible); only two also match 'l'.
    cb = Crysterm::Widget::ComboBox.new parent: s, editable: true, width: 12,
      options: ["alpha", "alabama", "beta", "gamma", "delta", "zeta"]

    # First char opens and sizes the popup: 6 matches, capped at max_visible (6),
    # plus the 2 border rows.
    cb.on_keypress cb_key('a')
    cb.open?.should be_true
    pop = cb.popup_widget.not_nil!
    pop.height.should eq 8

    # Narrowing to "al" leaves 2 matches; the popup must shrink to fit them.
    cb.on_keypress cb_key('l')
    pop.height.should eq 4

    # Backspacing back to "a" widens the matches again; the popup must regrow.
    cb.on_keypress Crysterm::Event::KeyPress.new('\u{0}', Tput::Key::Backspace)
    pop.height.should eq 8
  end
end
