# Example: Crysterm::Widget::Pine::MainMenu
#
# Minimal, self-contained example of a single MainMenu.
# Run it:     crystal run tests/widget/pine/main_menu/main_menu.cr
require "../../example"

alias CT = Crysterm
alias CW = CT::Widgets

Crysterm::WidgetExample.run "MainMenu" do |window|
  window.stylesheet = "MainMenu { border: solid; color: #c0caf5; }"
  mm = CW::PineMainMenu.new parent: window, top: "center", left: "center", width: 52, height: 12, label: " Main Menu "
  mm.options = ([
    CW::PineMainMenu::Option.new("C", "Compose", "Compose and send a message"),
    CW::PineMainMenu::Option.new("I", "Message Index", "View messages in the current folder"),
    CW::PineMainMenu::Option.new("L", "Folder List", "Select a folder to view"),
    CW::PineMainMenu::Option.new("A", "Address Book", "Update your address book"),
  ])
  mm.focus
end
