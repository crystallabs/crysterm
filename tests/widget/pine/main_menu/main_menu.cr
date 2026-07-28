# Example: Crysterm::Widget::Pine::MainMenu
#
# Minimal, self-contained example of a single MainMenu.
# Run it:     crystal run tests/widget/pine/main_menu/main_menu.cr
require "../../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run "MainMenu" do |window|
  window.stylesheet = "MainMenu { border: solid; color: #c0caf5; }"
  mm = PineMainMenu.new parent: window, top: "center", left: "center", width: 52, height: 12, label: " Main Menu "
  mm.options = ([
    PineMainMenu::Option.new("C", "Compose", "Compose and send a message"),
    PineMainMenu::Option.new("I", "Message Index", "View messages in the current folder"),
    PineMainMenu::Option.new("L", "Folder List", "Select a folder to view"),
    PineMainMenu::Option.new("A", "Address Book", "Update your address book"),
  ])
  mm.focus
end
