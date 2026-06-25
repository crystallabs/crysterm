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
      class AddressBook < Widget::List
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

        # The contacts currently displayed, parallel to the list rows.
        getter contacts = [] of Contact

        def initialize(
          contacts : Array(Contact) = [] of Contact,
          **list,
        )
          super **list

          styles.selected = Style.new reverse: true

          set_contacts contacts

          on ::Crysterm::Event::ActionItem do |_e|
            run_selected
          end
        end

        # Replaces the displayed contacts.
        def set_contacts(contacts : Array(Contact))
          @contacts = contacts
          set_items contacts.map { |c| format_contact c }
        end

        # The currently-selected contact, if any.
        def selected_contact : Contact?
          @contacts[selected]?
        end

        # Selects the currently-highlighted contact.
        def run_selected
          selected_contact.try &.callback.try &.call
        end

        # Formats one contact into a nickname / name / email row.
        private def format_contact(c : Contact) : String
          "  #{c.nickname.ljust(10)}#{c.name.ljust(24)}#{c.email}"
        end
      end
    end
  end
end
