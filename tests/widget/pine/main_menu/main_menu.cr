# Example: Crysterm::Widget::Pine::MainMenu
#
# Minimal, self-contained example of a single MainMenu.
# Run it:     crystal run examples/widget/pine/main_menu/main_menu.cr
# Maintained by tools/manage-examples.cr
require "../../example"

Crysterm::WidgetExample.run "MainMenu" do |screen|
  screen.stylesheet = "Pine::MainMenu { border: solid; color: #c0caf5; }"
  mm = Crysterm::Widget::Pine::MainMenu.new parent: screen, top: "center", left: "center", width: 52, height: 12, label: " Main Menu "
  mm.options = ([
    Crysterm::Widget::Pine::MainMenu::Option.new("C", "Compose", "Compose and send a message"),
    Crysterm::Widget::Pine::MainMenu::Option.new("I", "Message Index", "View messages in the current folder"),
    Crysterm::Widget::Pine::MainMenu::Option.new("L", "Folder List", "Select a folder to view"),
    Crysterm::Widget::Pine::MainMenu::Option.new("A", "Address Book", "Update your address book"),
  ])
  mm.focus
end
