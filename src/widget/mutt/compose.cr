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
      # `-- Attachments --` divider and the list of attachments (the message
      # body itself is always the first attachment in Mutt).
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
      # It is laid out as a `VBox`: the header row (`#header_box`, an `HBox`
      # holding the header menu and whatever the host appends beside it: help
      # for the highlighted field, a preview), the divider line, then the
      # attachment menu filling the rest. To the user it is still one
      # navigable **menu**: the arrow keys move the highlight through the
      # header lines *and* the attachments alike, crossing the divider, and
      # Enter acts on the highlighted row, which the compose reports as
      # `Event::ItemActivated` on itself with the row's index over the whole
      # menu (`#row_at`).
      #
      # The widget edits nothing itself: the host inspects `#selected_row` to
      # route Enter/clicks to the right edit, and pops its own prompt for header
      # edits.
      # Excluded from the DOM-loader registry: self-populating composite
      # (see `Crysterm::DOM::Skip`).
      @[::Crysterm::DOM::Skip]
      class Compose < Widget::Box
        include Mixin::NavKeys

        # The default header fields, in order (see `#fields`). All are
        # display-only except as the host wires them; From is conventionally
        # fixed.
        FIELDS = ["From", "To", "Cc", "Bcc", "Subject"]

        # The header fields this menu shows, in order; `FIELDS` unless the host
        # composes something other than mail (a task, a ticket, …).
        getter fields : Array(String)

        def fields=(names : Array(String)) : Array(String)
          @fields = names
          refresh
          names
        end

        # The word in the divider line: `-- Attachments (2) ----`.
        getter separator_label : String = "Attachments"

        def separator_label=(label : String) : String
          @separator_label = label
          refresh
          label
        end

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

        # The header row: the header menu on the left and, appended here by the
        # host, anything to show beside the headers. It is as tall as there are
        # fields; an appended widget takes the width it asks for, the menu the
        # rest.
        getter header_box : Widget::Box

        # The two halves of the menu: the header rows, and the attachment rows.
        getter headers_menu : Widget::List
        getter attachments_menu : Widget::List

        # The `-- Attachments --` divider line between them.
        getter divider : Widget::Box

        # Whether `j`/`k`/`g`/`G` move the highlight as well.
        property? vi_keys : Bool = false

        def initialize(**opts)
          super **opts

          @headers = Hash(String, String).new { |_, _| "" }
          @attachments = [] of Attachment
          @fields = FIELDS.dup
          @active = RowKind::Header

          @layout = Crysterm::Layout::VBox.new

          @header_box = Widget::Box.new(window: window, height: FIELDS.size, layout: Crysterm::Layout::HBox.new)
          @headers_menu = Widget::List.new(window: window, parse_tags: true, keys: false)
          @divider = Widget::Box.new(window: window, height: 1)
          @attachments_menu = Widget::List.new(window: window, parse_tags: true, keys: false)
          @header_box.append @headers_menu
          append @header_box
          append @divider
          append @attachments_menu

          {@headers_menu, @attachments_menu}.each do |menu|
            menu.styles.selected = Style.new reverse: true
            # A single click edits the highlighted row.
            menu.activate_on_click = true
            # Navigation is the compose's, not the lists' (`keys` is off), so the
            # highlight can cross from one half to the other.
            menu.on(::Crysterm::Event::KeyPress) { |e| navigate(menu, e) }
            menu.on(::Crysterm::Event::FocusIn) { @active = menu == @headers_menu ? RowKind::Header : RowKind::Attachment }
            menu.on(::Crysterm::Event::ItemActivated) { |e| emit ::Crysterm::Event::ItemActivated, e.item, index_of(menu, e.index) }
          end
          refresh
        end

        # The half of the menu that holds the highlight: focus it to give the
        # compose the keyboard.
        def menu : Widget::List
          @active.attachment? ? @attachments_menu : @headers_menu
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
          @fields.size
        end

        # What the menu row at *index* represents, plus its sub-index: a header
        # field number (into `#fields`), the attachment number, or `-1` for the
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
          @active.attachment? ? {RowKind::Attachment, @attachments_menu.current_index} : {RowKind::Header, @headers_menu.current_index}
        end

        # The index over the whole menu of the row at *index* of *menu*.
        def index_of(menu : Widget::List, index : Int32) : Int32
          menu == @attachments_menu ? separator_index + 1 + index : index
        end

        # Rebuilds the rows from the current state.
        def refresh
          # Mutt right-justifies the field labels so the colons line up, unlike
          # Pine's left-justified `To      :`. Header values are user-typed
          # text on a tag-parsing menu, so escape their braces.
          width = (@fields.max_of?(&.size) || 0) + 2
          @headers_menu.items = @fields.map { |f| "{bold}#{"#{f}:".rjust(width)}{/bold} #{Widget.escape_tags(@headers[f])}" }
          @header_box.height = @fields.size
          @divider.content = separator
          @attachments_menu.items = @attachments.map_with_index { |a, i| format_attachment(a, i) }
          @active = RowKind::Header if @attachments.empty?
        end

        # Moves the highlight for a navigation key, crossing the divider at
        # either end of a half; Enter activates the highlighted row.
        private def navigate(menu : Widget::List, e : ::Crysterm::Event::KeyPress) : Nil
          in_headers = menu == @headers_menu
          last = (in_headers ? @fields.size : @attachments.size) - 1
          case nav_intent(e)
          when .backward?
            !in_headers && menu.current_index <= 0 ? cross(@headers_menu, @fields.size - 1) : menu.up
          when .forward?
            in_headers && menu.current_index >= last ? cross(@attachments_menu, 0) : menu.down
          when .first?
            # Home and End span the whole menu; the paging keys stay in a half.
            in_headers ? menu.current_index = 0 : cross(@headers_menu, 0)
          when .last?
            in_headers && !@attachments.empty? ? cross(@attachments_menu, @attachments.size - 1) : menu.current_index = last
          when .page_backward?, .half_backward?
            menu.current_index = 0
          when .page_forward?, .half_forward?
            menu.current_index = last
          else
            return unless e.key == ::Tput::Key::Enter
            menu.activate_current
          end
          e.accept
          update!
        end

        # Puts the highlight on row *index* of the other half, when it has rows.
        private def cross(target : Widget::List, index : Int32) : Nil
          return if (target == @attachments_menu ? @attachments.size : @fields.size) == 0
          target.current_index = index
          target.focus
        end

        # The `-- Attachments --` divider line, dash-padded.
        private def separator : String
          label = "-- #{@separator_label} (#{@attachments.size}) "
          label + "-" * Math.max(0, 62 - label.size)
        end

        # Formats one attachment row, Mutt-style.
        private def format_attachment(a : Attachment, index : Int32) : String
          # Filenames are external data on a tag-parsing menu: escape braces.
          "  #{(index + 1).to_s.rjust(2)} #{Widget.escape_tags(a.filename).ljust(24)} [#{a.mime_type}, #{Crysterm::Formatting.human_size(a.size)}]"
        end
      end
    end
  end
end
