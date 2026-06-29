require "./spec_helper"

include Crysterm

private def pmm_screen
  Crysterm::Screen.new(
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

# `MainMenu` spaces its options apart with real list `item_spacing` (the gaps
# are NOT items), instead of the old blank spacer rows. So there are no empty
# rows to land on: the model is a clean 1:1 list of options, and the cursor
# always sits on a real option.
describe "Pine::MainMenu spaced navigation" do
  it "has one item per option (no blank spacer rows)" do
    s = pmm_screen
    menu = Crysterm::Widget::Pine::MainMenu.new pmm_options, parent: s
    menu.ritems.size.should eq 3
    menu.ritems.none?(&.strip.empty?).should be_true
  end

  it "renders the options spaced apart via item_spacing" do
    s = pmm_screen
    menu = Crysterm::Widget::Pine::MainMenu.new pmm_options, parent: s, top: 0, left: 0, width: 60, height: 12
    s._render
    menu.item_spacing.should eq 1
    menu.@items.map(&.atop).should eq [0, 2, 4] # a blank row between each
  end

  it "steps one option at a time, clamped at the ends" do
    s = pmm_screen
    menu = Crysterm::Widget::Pine::MainMenu.new pmm_options, parent: s

    menu.selekt 0
    menu.selected_record.try(&.title).should eq "HELP"
    press menu, Tput::Key::Down
    menu.selected.should eq 1
    menu.selected_record.try(&.title).should eq "COMPOSE"
    press menu, Tput::Key::Down
    menu.selected.should eq 2
    menu.selected_record.try(&.title).should eq "INDEX"
    press menu, Tput::Key::Down
    menu.selected.should eq 2 # clamped at the last option
    press menu, Tput::Key::Up
    menu.selected.should eq 1
  end
end
