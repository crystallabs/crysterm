# Example: Crysterm::Widget::Pine::AddressBook
#
# Minimal, self-contained example of a single AddressBook.
# Run it:     crystal run examples/widget/pine/address_book/address_book.cr
# Maintained by tools/manage-examples.cr
require "../../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run "AddressBook" do |window|
  window.stylesheet = "Pine::AddressBook { border: solid; color: #c0caf5; }"
  ab = PineAddressBook.new parent: window, top: "center", left: "center", width: 50, height: 12, label: " Address Book "
  ab.contacts = ([
    PineAddressBook::Contact.new("ada", "Ada Lovelace", "ada@example.com"),
    PineAddressBook::Contact.new("linus", "Linus Torvalds", "linus@example.org"),
    PineAddressBook::Contact.new("grace", "Grace Hopper", "grace@example.net"),
  ])
  ab.focus
end
