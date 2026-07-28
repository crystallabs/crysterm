# Example: Crysterm::Widget::Pine::KeyMenu
#
# Minimal, self-contained example of a single KeyMenu.
# Run it:     crystal run tests/widget/pine/key_menu/key_menu.cr
require "../../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run "KeyMenu" do |window|
  window.stylesheet = "KeyMenu { color: #c0caf5; }"
  km = PineKeyMenu.new parent: window, bottom: 0, left: 0, width: "100%", height: 2
  km.entries = [
    PineKeyMenu::Entry.new("?", "Help"), PineKeyMenu::Entry.new("C", "Compose"),
    PineKeyMenu::Entry.new("D", "Delete"), PineKeyMenu::Entry.new("R", "Reply"),
    PineKeyMenu::Entry.new("Q", "Quit"),
  ]
end
