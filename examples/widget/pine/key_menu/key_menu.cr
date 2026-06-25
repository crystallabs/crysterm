# Example: Crysterm::Widget::Pine::KeyMenu
#
# Minimal, self-contained example of a single KeyMenu.
# Run it:     crystal run examples/widget/pine/key_menu/key_menu.cr
# Maintained by tools/manage-examples.cr
require "../../example"

Crysterm::WidgetExample.run "KeyMenu" do |screen|
  screen.stylesheet = "Pine::KeyMenu { color: #c0caf5; }"
  km = Crysterm::Widget::Pine::KeyMenu.new parent: screen, bottom: 0, left: 0, width: "100%", height: 2
  km.set_entries([
    Crysterm::Widget::Pine::KeyMenu::Entry.new("?", "Help"), Crysterm::Widget::Pine::KeyMenu::Entry.new("C", "Compose"),
    Crysterm::Widget::Pine::KeyMenu::Entry.new("D", "Delete"), Crysterm::Widget::Pine::KeyMenu::Entry.new("R", "Reply"),
    Crysterm::Widget::Pine::KeyMenu::Entry.new("Q", "Quit"),
  ])
end
