# Example: Crysterm::Widget::Pine::AddressBook
#
# Minimal, self-contained example of a single AddressBook.
# Run it:     crystal run tests/widget/pine/address_book/address_book.cr
require "../../example"

alias CT = Crysterm
alias CW = CT::Widgets

Crysterm::WidgetExample.run "AddressBook" do |window|
  window.stylesheet = "AddressBook { border: solid; color: #c0caf5; }"
  ab = CW::PineAddressBook.new parent: window, top: "center", left: "center", width: 50, height: 12, label: " Address Book "
  ab.contacts = ([
    CW::PineAddressBook::Contact.new("ada", "Ada Lovelace", "ada@example.com"),
    CW::PineAddressBook::Contact.new("linus", "Linus Torvalds", "linus@example.org"),
    CW::PineAddressBook::Contact.new("grace", "Grace Hopper", "grace@example.net"),
  ])
  ab.focus
end
