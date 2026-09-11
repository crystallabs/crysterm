# Example: Crysterm::Widget::Pine::KeyMenu
#
# Minimal, self-contained example of a single KeyMenu.
# Run it:     crystal run tests/widget/pine/key_menu/key_menu.cr
require "../../example"

alias CT = Crysterm
alias CW = CT::Widgets

Crysterm::WidgetExample.run "KeyMenu" do |window|
  window.stylesheet = "KeyMenu { color: #c0caf5; }"
  km = CW::PineKeyMenu.new parent: window, bottom: 0, left: 0, width: "100%", height: 2
  km.entries = [
    CW::PineKeyMenu::Entry.new("?", "Help"), CW::PineKeyMenu::Entry.new("C", "Compose"),
    CW::PineKeyMenu::Entry.new("D", "Delete"), CW::PineKeyMenu::Entry.new("R", "Reply"),
    CW::PineKeyMenu::Entry.new("Q", "Quit"),
  ]
end
