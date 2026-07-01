require "./spec_helper"

include Crysterm

# Editable `ComboBox` sizes its drop-down to the match count (`#position_popup`:
# height = min(matches, max_visible) + border). The first typed character opens
# and sizes the popup, but subsequent keystrokes routed through `#refresh_popup`,
# which refreshed rows without re-sizing — stale height once the filter
# narrowed or widened. `#refresh_popup` must re-run `#position_popup`.

private def combo_mem_screen
  Crysterm::Window.new(
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

    # First char opens and sizes popup: 6 matches, capped at max_visible (6),
    # plus 2 border rows.
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
