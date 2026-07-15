# Example: Crysterm::Widget::Pine::AddressBook
#
# Minimal, self-contained example of a single AddressBook.
# Run it:     crystal run examples/widget/pine/address_book/address_book.cr
# Maintained by tools/manage-examples.cr
require "../../example"

Crysterm::WidgetExample.run "AddressBook" do |screen|
  screen.stylesheet = "Pine::AddressBook { border: solid; color: #c0caf5; }"
  ab = Crysterm::Widget::Pine::AddressBook.new parent: screen, top: "center", left: "center", width: 50, height: 12, label: " Address Book "
  ab.contacts = ([
    Crysterm::Widget::Pine::AddressBook::Contact.new("ada", "Ada Lovelace", "ada@example.com"),
    Crysterm::Widget::Pine::AddressBook::Contact.new("linus", "Linus Torvalds", "linus@example.org"),
    Crysterm::Widget::Pine::AddressBook::Contact.new("grace", "Grace Hopper", "grace@example.net"),
  ])
  ab.focus
end
