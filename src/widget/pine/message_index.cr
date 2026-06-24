module Crysterm
  class Widget
    module Pine
      # The Pine/Alpine MESSAGE INDEX: a scrollable list of messages in the
      # current folder, one per row, with columns for status, number, date,
      # sender, size and subject:
      #
      # ```
      # + N   1  Jun 20  Mailer Daemon        (1,234) Welcome to Alpine
      #   N   2  Jun 20  John Smith           (5,678) Re: Project update
      # ```
      #
      # The selected row is drawn reverse. Navigate with the arrow keys; Enter
      # activates the message (runs its `callback` and emits `Event::ActionItem`).
      #
      # <!-- widget-examples:capture v1 -->
      # ![MessageIndex screenshot](../../../examples/widget/pine/message_index/message_index-capture.png)
      # <!-- /widget-examples:capture -->
      class MessageIndex < Widget::List
        # A single message row.
        class Message
          # Status flags shown at the very left (e.g. `"+"`, `"N"`, `"D"`, `"A"`).
          property status : String

          # Sender display name.
          property from : String

          # Short date string (e.g. `"Jun 20"`).
          property date : String

          # Subject line.
          property subject : String

          # Size, in bytes (rendered grouped, e.g. `(1,234)`).
          property size : Int32

          # Whether the message is unread (shown with an `N` flag by default).
          property? unread : Bool

          # Action invoked when the message is activated.
          property callback : Proc(Nil)?

          def initialize(@from, @subject, *, @date = "", @size = 0, @status = "", @unread = false, @callback = nil)
          end
        end

        # The messages currently displayed, parallel to the list items.
        getter messages = [] of Message

        def initialize(
          messages : Array(Message) = [] of Message,
          **list,
        )
          super **list

          styles.selected = Style.new reverse: true

          set_messages messages

          on ::Crysterm::Event::ActionItem do |e|
            run_selected
          end
        end

        # Replaces the displayed messages.
        def set_messages(messages : Array(Message))
          @messages = messages
          set_items messages.map_with_index { |m, i| format_message(m, i + 1) }
        end

        # The currently-selected message, if any.
        def selected_message : Message?
          @messages[selected]?
        end

        # Activates the currently-selected message.
        def run_selected
          selected_message.try &.callback.try &.call
        end

        # Formats one message into a fixed-column row.
        private def format_message(m : Message, number : Int32) : String
          status = m.status.presence || (m.unread? ? "N" : " ")
          String.build do |s|
            s << status.ljust(3)
            s << number.to_s.rjust(3)
            s << "  "
            s << m.date.ljust(7)
            s << "  "
            s << truncate(m.from, 20).ljust(20)
            s << " ("
            s << group_digits(m.size).rjust(7)
            s << ") "
            s << m.subject
          end
        end

        # Truncates *str* to *len* characters, adding an ellipsis when cut.
        private def truncate(str : String, len : Int32) : String
          return str if str.size <= len
          "#{str[0, len - 1]}~"
        end

        # Formats an integer with thousands separators, e.g. `1234 => "1,234"`.
        private def group_digits(n : Int32) : String
          s = n.to_s
          neg = s.starts_with?('-')
          digits = neg ? s[1..] : s
          grouped = digits.reverse.gsub(/(\d{3})(?=\d)/, "\\1,").reverse
          neg ? "-#{grouped}" : grouped
        end
      end
    end
  end
end
