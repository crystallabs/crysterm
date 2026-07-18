require "../../widget_pine_selectable_list"

module Crysterm
  class Widget
    module Mutt
      # A single message row in the `MessageIndex`.
      class Message
        # Sender display name.
        property from : String

        # Subject line.
        property subject : String

        # Short date string (e.g. `"Jun 20"`).
        property date : String

        # Size, in bytes.
        property size : Int32

        # Status flags shown in the `%Z` column, e.g. `"N"` (new), `"D"`
        # (deleted), `"r"` (replied), `"*"` (flagged), `"!"` (important).
        property status : String

        # Threading depth: 0 for a thread root, 1 for a direct reply, etc. Drives
        # the tree glyphs drawn before the subject.
        property depth : Int32

        # Whether the message is unread.
        property? unread : Bool

        # Action invoked when the message is activated (Enter / click).
        property callback : Proc(Nil)?

        def initialize(@from, @subject, *, @date = "", @size = 0, @status = "", @depth = 0, @unread = false, @callback = nil)
        end

        # Block form: `Message.new(from, subject, ...) { ... }`.
        def initialize(from, subject, *, date = "", size = 0, status = "", depth = 0, unread = false, &callback : ->)
          initialize(from, subject, date: date, size: size, status: status, depth: depth, unread: unread, callback: callback)
        end
      end

      # Mutt's **message index**, the threaded counterpart to Pine's flat
      # `MessageIndex`. It draws the ASCII/Unicode **thread tree** before each
      # subject, computed from each message's `depth`:
      #
      # ```
      #    1 N Jun 18  Alpine Team        (1.2K) Welcome to Mutt!
      #    2   Jun 19  John Smith         (5.5K) Project update
      #    3 r Jun 19  Jane Doe           ( 842) ├─>Re: Project update
      #    4   Jun 20  John Smith         (1.1K) │ └─>Re: Project update
      #    5   Jun 21  Crystal Weekly     (8.7K) └─>Macros deep-dive
      # ```
      #
      # The selected row is drawn reverse. Navigate with the arrow keys; Enter
      # activates the message (runs its `callback` and emits `Event::ItemActivated`).
      class MessageIndex < ::Crysterm::Widget::Pine::SelectableList(Message)
        # Nested-name alias for the record type.
        alias Message = ::Crysterm::Widget::Mutt::Message

        # Thread-tree glyphs (Mutt's `$ascii_chars` off). Override for a
        # pure-ASCII look: `vline: "| ", tee: "|-", corner: "`-", ...`.
        property tree_vline : String = "│ "
        property tree_gap : String = "  "
        property tree_tee : String = "├─"
        property tree_corner : String = "└─"
        property tree_arrow : String = ">"

        def initialize(
          messages : Array(Message) = [] of Message,
          **list,
        )
          super messages, **list
        end

        record_accessors messages, message, Message

        # Formats one message into a fixed-column row with a thread-tree prefix.
        def format_row(item : Message, index : Int32) : String
          String.build do |s|
            s << (index + 1).to_s.rjust(4)
            s << ' '
            s << (item.status.presence || (item.unread? ? "N" : " ")).ljust(2)
            s << ' '
            s << item.date.ljust(6)
            s << "  "
            s << truncate(item.from, 16).ljust(16)
            s << " ("
            s << human_size(item.size).rjust(5)
            s << ") "
            s << thread_prefix(index)
            s << item.subject
          end
        end

        # Builds the thread-tree prefix for the message at *index* from the depths
        # of the surrounding messages: a tee (`├─`), or a corner (`└─`) when it is
        # the last reply at its level, preceded by one continuation line (`│`) or
        # gap per ancestor level.
        private def thread_prefix(index : Int32) : String
          d = records[index].depth
          return "" if d <= 0
          String.build do |s|
            # Ancestor columns: depth 1 .. d-1.
            (1...d).each do |level|
              s << (ancestor_continues?(index, level) ? tree_vline : tree_gap)
            end
            s << (last_at_level?(index, d) ? tree_corner : tree_tee)
            s << tree_arrow
          end
        end

        # Whether the message at *index* is the last one in its sibling group at
        # *depth*, i.e. no later message sits at `depth` before the thread pops
        # back out to a shallower level.
        private def last_at_level?(index : Int32, depth : Int32) : Bool
          (index + 1...records.size).each do |j|
            dj = records[j].depth
            return true if dj < depth
            return false if dj == depth
          end
          true
        end

        # Whether the ancestor branch at *level* has a further sibling below
        # *index*, so its vertical connector continues.
        private def ancestor_continues?(index : Int32, level : Int32) : Bool
          (index + 1...records.size).each do |j|
            dj = records[j].depth
            return false if dj < level
            return true if dj == level
          end
          false
        end

        # Truncates *str* to *len* characters, adding a `~` when cut (Mutt style).
        private def truncate(str : String, len : Int32) : String
          return str if str.size <= len
          "#{str[0, len - 1]}~"
        end

        # Formats a byte count the way Mutt's `%c` does: bytes, then `K`/`M` with
        # one decimal (e.g. `842`, `1.2K`, `3.4M`).
        private def human_size(n : Int32) : String
          if n < 1000
            n.to_s
          elsif n < 1_000_000
            "%.1fK" % (n / 1000.0)
          else
            "%.1fM" % (n / 1_000_000.0)
          end
        end
      end
    end
  end
end
