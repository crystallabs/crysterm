require "../../widget_pine_selectable_list"

module Crysterm
  class Widget
    module Pine
      # The Pine/Alpine ADDRESS BOOK: a selectable list of contacts, each with a
      # short nickname, a full name and an email address.
      #
      # ```
      #   john     John Smith            john.smith@example.com
      #   jane     Jane Doe              jane@example.com
      # ```
      #
      # Navigate with the arrow keys; Enter selects the contact (runs its
      # `callback` — e.g. to start composing a message to them).
      #
      # <!-- widget-examples:capture v1 -->
      # ![AddressBook screenshot](../../../examples/widget/pine/address_book/address_book-capture5s.apng)
      # <!-- /widget-examples:capture -->
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

      class AddressBook < SelectableList(Contact)
        # Historical nested name for the record type (see `SelectableList`).
        alias Contact = ::Crysterm::Widget::Pine::Contact

        def initialize(
          contacts : Array(Contact) = [] of Contact,
          **list,
        )
          super contacts, **list
        end

        # The contacts currently displayed, parallel to the list rows.
        def contacts : Array(Contact)
          records
        end

        # Replaces the displayed contacts.
        def set_contacts(contacts : Array(Contact))
          set_records contacts
        end

        # The currently-selected contact, if any.
        def selected_contact : Contact?
          selected_record
        end

        # Selects the currently-highlighted contact.
        def run_selected
          activate
        end

        # Formats one contact into a nickname / name / email row.
        def format_row(item : Contact, index : Int32) : String
          "  #{item.nickname.ljust(10)}#{item.name.ljust(24)}#{item.email}"
        end
      end
    end
  end
end
