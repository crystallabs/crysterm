require "../box"
require "../list"

module Crysterm
  class Widget
    module Mutt
      # A single attachment row in the `Compose` screen.
      class Attachment
        # File name shown to the user.
        property filename : String

        # MIME type, e.g. `"text/plain"` or `"image/png"`.
        property mime_type : String

        # Size in bytes.
        property size : Int32

        # Content-disposition, e.g. `"inline"` or `"attachment"`.
        property disposition : String

        def initialize(@filename, @mime_type = "application/octet-stream", @size = 0, @disposition = "attachment")
        end
      end

      # Mutt's **compose** screen: a block of editable headers above a
      # `-- Attachments --` separator and the list of attachments (the message
      # body itself is always the first attachment in Mutt). It is a single
      # navigable **menu**: the arrow keys move the highlight through the header
      # lines *and* the attachments alike, and Enter acts on the highlighted row.
      # It is therefore a single `List` — headers, a non-selectable
      # `-- Attachments --` divider the cursor steps over, then attachment rows —
      # rather than a static header `Box` stacked over a separate list.
      #
      # ```
      #     From: you@example.com
      #       To: john@example.com
      #       Cc:
      #  Subject: Re: Project update
      # -- Attachments ------------------------------------------------
      #   1 (message body)           [text/plain, 1.2K]
      #   2 patch.diff               [text/x-diff, 4.0K]
      # ```
      #
      # The widget edits nothing itself: the host inspects `#selected_row` to
      # route Enter/clicks to the right edit, and pops its own prompt for header
      # edits.
      class Compose < Widget::Box
        # The header fields shown, in order. All are display-only except as the
        # host wires them; From is conventionally fixed.
        FIELDS = ["From", "To", "Cc", "Bcc", "Subject"]

        # What a menu row represents, returned alongside a sub-index (which header
        # field, or which attachment).
        enum RowKind
          Header
          Separator
          Attachment
        end

        # Current header values, keyed by field name.
        getter headers : Hash(String, String)

        # The attachments (the body is conventionally the first one).
        getter attachments : Array(Attachment)

        # The single navigable menu: header rows, the `-- Attachments --` divider,
        # then attachment rows.
        getter menu : Widget::List

        def initialize(**opts)
          super **opts

          @headers = Hash(String, String).new { |_, _| "" }
          @attachments = [] of Attachment

          @layout = Crysterm::Layout::VBox.new

          @menu = Widget::List.new(width: "100%", height: "100%", parse_tags: true)
          @menu.styles.selected = Style.new reverse: true
          # A single click edits the highlighted row; the divider ignores clicks.
          @menu.activate_on_click = true

          append @menu
          refresh
        end

        # Sets a header field's value (creating it if the field name is custom).
        def set_header(name : String, value : String)
          @headers[name] = value
          refresh
        end

        # Returns a header field's current value (empty string if unset).
        def header(name : String) : String
          @headers[name]
        end

        # Appends an attachment and refreshes the list.
        def add_attachment(att : Attachment)
          @attachments << att
          refresh
        end

        # Removes all attachments.
        def clear_attachments
          @attachments.clear
          refresh
        end

        # Clears every header and attachment (a fresh message).
        def reset
          @headers.clear
          @attachments.clear
          refresh
        end

        # The menu index of the `-- Attachments --` divider (the row count of the
        # header block). Rows before it are headers; rows after are attachments.
        def separator_index : Int32
          FIELDS.size
        end

        # What the menu row at *index* represents, plus its sub-index: a header
        # field number (into `FIELDS`), the attachment number, or `-1` for the
        # divider.
        def row_at(index : Int32) : {RowKind, Int32}
          sep = separator_index
          if index < sep
            {RowKind::Header, index}
          elsif index == sep
            {RowKind::Separator, -1}
          else
            {RowKind::Attachment, index - sep - 1}
          end
        end

        # The role + sub-index of the currently highlighted menu row.
        def selected_row : {RowKind, Int32}
          row_at @menu.current_index
        end

        # Rebuilds the menu rows from the current state, re-marking the divider as
        # non-selectable so the cursor steps over it.
        def refresh
          rows = [] of String
          # Mutt right-justifies the field labels so the colons line up, unlike
          # Pine's left-justified `To      :`.
          FIELDS.each { |f| rows << "{bold}#{"#{f}:".rjust(9)}{/bold} #{@headers[f]}" }
          rows << separator
          @attachments.each_with_index { |a, i| rows << format_attachment(a, i) }
          @menu.items = rows
          @menu.non_selectable_rows = [separator_index]
        end

        # The `-- Attachments --` divider line, dash-padded.
        private def separator : String
          label = "-- Attachments (#{@attachments.size}) "
          label + "-" * Math.max(0, 62 - label.size)
        end

        # Formats one attachment row, Mutt-style.
        private def format_attachment(a : Attachment, index : Int32) : String
          "  #{(index + 1).to_s.rjust(2)} #{a.filename.ljust(24)} [#{a.mime_type}, #{human_size(a.size)}]"
        end

        # Byte count as bytes / `K` / `M`, matching `MessageIndex`.
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
