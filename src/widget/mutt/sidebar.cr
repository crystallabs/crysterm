require "../../widget_pine_selectable_list"

module Crysterm
  class Widget
    module Mutt
      # A single mailbox row in the `Sidebar`.
      class Mailbox
        # Mailbox name as shown (e.g. `"INBOX"` or, for a nested maildir, the
        # last path component `"lists.crystal"`).
        property name : String

        # Number of unread messages (shown right-aligned; hidden when zero).
        property unread : Int32

        # Total number of messages.
        property total : Int32

        # Number of flagged ("important") messages.
        property flagged : Int32

        # Whether the mailbox has newly-arrived mail (Mutt bolds these).
        property? new : Bool

        # Nesting depth for indentation of hierarchical mailboxes (0 = top).
        property depth : Int32

        # Action invoked when the mailbox is opened (Enter / click).
        property callback : Proc(Nil)?

        def initialize(@name, @unread = 0, @total = 0, *, @flagged = 0, @new = false, @depth = 0, @callback = nil)
        end
      end

      # Mutt's signature **sidebar**: a narrow, always-visible pane listing the
      # user's mailboxes with their unread/total counts, drawn to the left of the
      # index/pager. This is the one piece of Mutt chrome that has no Pine/Alpine
      # analogue, so it earns its own widget; everything else reuses the same
      # `SelectableList` machinery the Pine widgets do.
      #
      # ```
      #  > INBOX             3
      #    lists
      #      crystal         12
      #      mutt
      #    Sent
      #    Trash             1
      # ```
      #
      # Two independent markers, mirroring Mutt: the **highlighted** row (the
      # cursor, drawn reverse via `styles.selected`) moves with the arrow keys,
      # while the **open** mailbox — the folder actually shown in the index — is
      # flagged with a `>` indicator and set via `#open=`. Enter/click on a row
      # runs its `callback` (and opens it).
      #
      # The divider Mutt draws between the sidebar and the main area is left to
      # the surrounding layout (e.g. a right border on this widget, or the
      # `Border` layout's edge), so the widget stays purely a list.
      class Sidebar < ::Crysterm::Widget::Pine::SelectableList(Mailbox)
        # Nested-name alias for the record type (see `SelectableList`).
        alias Mailbox = ::Crysterm::Widget::Mutt::Mailbox

        # Index of the currently-open mailbox (the one shown in the index), or a
        # negative value for none. Rendered with a `>` indicator.
        getter open_index : Int32 = -1

        # Visible column width used to right-align the counts. Defaults to the
        # widget's own `width` when that is a fixed integer.
        property col_width : Int32

        def initialize(
          mailboxes : Array(Mailbox) = [] of Mailbox,
          *,
          col_width : Int32? = nil,
          **list,
        )
          # Resolve the count column width from the configured width when the
          # caller doesn't override it (an integer width; percentage widths fall
          # back to a sensible default).
          @col_width = col_width || (list[:width]?.as?(Int32)) || 22
          super mailboxes, **list
        end

        record_accessors mailboxes, mailbox, Mailbox

        # Sets the open mailbox by index and rebuilds the rows so the `>`
        # indicator moves. Pass a negative value for "no open mailbox".
        def open=(index : Int32)
          @open_index = index
          set_records records
        end

        # Formats one mailbox: an open-indicator, the (indented) name, and the
        # right-aligned unread count.
        def format_row(item : Mailbox, index : Int32) : String
          lead = index == @open_index ? "> " : "  "
          name = ("  " * item.depth) + item.name
          count = item.unread > 0 ? item.unread.to_s : ""
          # Reserve two cells for the leading indicator and one trailing space.
          avail = @col_width - lead.size - count.size - 1
          avail = 1 if avail < 1
          name = name.size > avail ? "#{name[0, avail - 1]}~" : name
          "#{lead}#{name.ljust(avail)} #{count}"
        end
      end
    end
  end
end
