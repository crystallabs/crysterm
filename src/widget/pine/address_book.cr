require "../../widget_pine_selectable_list"

module Crysterm
  class Widget
    module Pine
      # Pine/Alpine address book: a selectable list of contacts, each with a
      # nickname, a full name, and an email address.
      #
      # ```
      #   john     John Smith            john.smith@example.com
      #   jane     Jane Doe              jane@example.com
      # ```
      #
      # Navigate with the arrow keys; Enter selects the contact (runs its
      # `callback` — e.g. to start composing a message to them).
      # A single address-book entry.
      class Contact
        # Short nickname / alias.
        property nickname : String

        # Full display name.
        property name : String

        # Email address.
        property email : String

        # Action invoked when the contact is selected.
        property callback : Proc(Nil)?

        def initialize(@nickname, @name, @email, *, @callback = nil)
        end

        # The contact formatted as a mail recipient: `Name <email>`.
        def recipient : String
          "#{name} <#{email}>"
        end
      end

      # <!-- widget-examples:capture v1 -->
      # ![AddressBook screenshot](../../../tests/widget/pine/address_book/address_book.5s.apng)
      # <!-- /widget-examples:capture -->
      class AddressBook < SelectableList(Contact)
        # Nested-name alias for the record type.
        alias Contact = ::Crysterm::Widget::Pine::Contact

        def initialize(
          contacts : Array(Contact) = [] of Contact,
          **list,
        )
          super contacts, **list
        end

        record_accessors contacts, contact, Contact

        # Formats one contact into a nickname / name / email row.
        def format_row(item : Contact, index : Int32) : String
          "  #{item.nickname.ljust(10)}#{item.name.ljust(24)}#{item.email}"
        end
      end
    end
  end
end
