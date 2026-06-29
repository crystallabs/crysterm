require "./spec_helper"

include Crysterm

private def pmm_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

private def pmm_options
  [
    Crysterm::Widget::Pine::MenuOption.new("?", "HELP", "Get help"),
    Crysterm::Widget::Pine::MenuOption.new("C", "COMPOSE", "Compose a message"),
    Crysterm::Widget::Pine::MenuOption.new("I", "INDEX", "View messages"),
  ]
end

private def press(menu, key : Tput::Key)
  menu.on_keypress Crysterm::Event::KeyPress.new('\0', key)
end

# `MainMenu` (spaced) interleaves blank spacer rows between options, so the real
# options sit on the *even* list rows. Arrow navigation must always land on an
# option, even if the selection started on an odd spacer row (reachable via a
# mouse click on a spacer or a PageUp/PageDown that fell through to the base
# handler). Before the fix, `move_to_option` stepped the raw row index by two,
# so an odd start stayed odd forever — the cursor got stuck cycling blank rows.
describe "Pine::MainMenu spaced navigation" do
  it "lands the cursor on an option row when navigating from a spacer" do
    s = pmm_screen
    menu = Crysterm::Widget::Pine::MainMenu.new pmm_options, parent: s

    # Simulate the cursor sitting on the blank spacer between option 0 and 1
    # (e.g. after a click on it). Spacers are the odd rows.
    menu.selekt 1
    menu.selected.should eq 1

    press menu, Tput::Key::Down
    # Must move to option 1 (row 2), not to the next spacer (row 3).
    menu.selected.should eq 2
    menu.selected.even?.should be_true
    menu.selected_record.try(&.title).should eq "COMPOSE"
  end

  it "moves onto an option row (never a spacer) when going up from a spacer" do
    s = pmm_screen
    menu = Crysterm::Widget::Pine::MainMenu.new pmm_options, parent: s

    menu.selekt 3 # the spacer below COMPOSE (grouped as option 1)
    press menu, Tput::Key::Up
    menu.selected.even?.should be_true # an option row, not a blank spacer
    menu.selected.should eq 0          # option 0 (HELP)
    menu.selected_record.try(&.title).should eq "HELP"
  end

  it "still steps one option at a time from an option row" do
    s = pmm_screen
    menu = Crysterm::Widget::Pine::MainMenu.new pmm_options, parent: s

    menu.selekt 0 # option 0 (HELP)
    press menu, Tput::Key::Down
    menu.selected.should eq 2 # option 1
    press menu, Tput::Key::Down
    menu.selected.should eq 4 # option 2
    press menu, Tput::Key::Down
    menu.selected.should eq 4 # clamped at the last option
    press menu, Tput::Key::Up
    menu.selected.should eq 2
  end
end
