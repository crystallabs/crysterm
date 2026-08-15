require "../record_list"

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
      # activates the message (runs its `callback` and emits `Event::ItemActivated`).
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

        # Block form of `#callback=`; the block's value is discarded, so the
        # body needs no trailing `nil`.
        def callback(&block : ->) : Nil
          @callback = block
        end

        def initialize(@from, @subject, *, @date = "", @size = 0, @status = "", @unread = false, @callback = nil)
        end

        # Block form: `Message.new(from, subject, ...) { ... }`.
        def initialize(from, subject, *, date = "", size = 0, status = "", unread = false, &callback : ->)
          initialize(from, subject, date: date, size: size, status: status, unread: unread, callback: callback)
        end
      end

      # <!-- widget-examples:capture v1 -->
      # ![MessageIndex screenshot](../../../tests/widget/pine/message_index/message_index.5s.apng)
      # <!-- /widget-examples:capture -->
      class MessageIndex < SelectableList(Message)
        # Nested-name alias for the record type.
        alias Message = ::Crysterm::Widget::Pine::Message

        # Width of the leftmost status/flags column. Defaults to Alpine's compact
        # 3 (a marker, a space, and one status char); every row pads its status to
        # this width, so widening it keeps the other columns aligned.
        getter status_width : Int32 = 3

        # :ditto: — reformats the already-loaded rows, so the column can be
        # widened after construction without reassigning `messages`.
        def status_width=(v : Int32)
          return v if v == @status_width
          @status_width = v
          self.records = records
          v
        end

        def initialize(
          messages : Array(Message) = [] of Message,
          **list,
        )
          super messages, **list
        end

        record_accessors messages, message, Message

        # Formats one message into a fixed-column row; *index* (0-based) becomes
        # the 1-based message number.
        def format_row(item : Message, index : Int32) : String
          format_message(item, index + 1)
        end

        private def format_message(m : Message, number : Int32) : String
          status = m.status.presence || (m.unread? ? "N" : " ")
          String.build do |s|
            s << status.ljust(status_width)
            s << number.to_s.rjust(3)
            s << "  "
            s << m.date.ljust(7)
            s << "  "
            # Suite-neutral helper, not `Mutt.truncate` — Pine must not depend
            # on the Mutt suite.
            s << Crysterm::Formatting.truncate(m.from, 20).ljust(20)
            s << " ("
            # Stdlib thousands grouping, e.g. `1234 => "1,234"`.
            s << m.size.format.rjust(7)
            s << ") "
            s << m.subject
          end
        end
      end
    end
  end
end
