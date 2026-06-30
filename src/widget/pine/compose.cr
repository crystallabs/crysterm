module Crysterm
  class Widget
    module Pine
      # The Pine/Alpine COMPOSE MESSAGE screen: a set of single-line header
      # fields (To, Cc, Bcc, Attchmnt, Subject) above a separator, followed by a
      # multi-line message-body editor.
      #
      # ```
      # To      : someone@example.com
      # Cc      :
      # Bcc     :
      # Attchmnt:
      # Subject : Hello
      # ----- Message Text -----
      # <body editor>
      # ```
      #
      # Move between fields with Tab / Shift-Tab (the `Screen`'s built-in focus
      # navigation). Each header field is a `Widget::LineEdit`; the body is a
      # `Widget::PlainTextEdit`. Values are exposed via `#values` for the demo.
      #
      # <!-- widget-examples:capture v1 -->
      # ![Compose screenshot](../../../tests/widget/pine/compose/compose.5s.apng)
      # <!-- /widget-examples:capture -->
      class Compose < Widget::Box
        # Header field names shown to the left of each input.
        FIELD_NAMES = ["To", "Cc", "Bcc", "Attchmnt", "Subject"]

        # The header input boxes, keyed by lower-cased field name.
        getter fields = {} of String => Widget::LineEdit

        # The message-body editor.
        getter! body : Widget::PlainTextEdit

        def initialize(**box)
          super **box

          # The composer stacks three vertical bands: the header (label/field
          # pairs), the separator, and the body. A `VBox` arranges them
          # top-to-bottom; the header and separator have fixed heights, so the
          # body (the only child without an explicit height) grows to fill the
          # remaining vertical space. Set the ivar directly (not `self.layout=`)
          # so it is in place before the children are appended below.
          @layout = Crysterm::Layout::VBox.new

          label_style = Style.new bold: true

          # The five label/field rows are a two-column form: a fixed 10-wide
          # label column (no gap, matching the old `left: 10` field origin) and a
          # field column that fills the rest of the width. The `Form` engine
          # pairs the appended children (label, field, label, field, …) into rows.
          header = Widget::Box.new(
            window: window,
            height: FIELD_NAMES.size,
            layout: Crysterm::Layout::Form.new(label_width: 10, gap: 0),
          )

          FIELD_NAMES.each do |name|
            label = Widget::Box.new(
              window: window,
              height: 1,
              content: "#{name.ljust(8)}:",
              style: label_style,
            )

            input = Widget::LineEdit.new(
              window: window,
              height: 1,
              content: "",
            )
            # In a header field, Enter advances to the next field (Pine), not
            # "submit-and-return". Don't rewind focus when the read finishes, and
            # turn the resulting `Submit` into a Tab so the screen's own focus
            # navigation moves on — the body keeps Enter as a newline (it emits no
            # `Submit`).
            input.rewind_on_done = false
            input.on(::Crysterm::Event::Submit) do
              window.emit ::Crysterm::Event::KeyPress.new('\0', ::Tput::Key::Tab)
            end
            # Up/Down move between fields (not input history) — single-line, so
            # there is no in-field vertical movement to preserve.
            input.history_keys = false

            @fields[name.downcase] = input
            header.append label
            header.append input
          end

          append header

          separator = Widget::Box.new(
            window: window,
            height: 1,
            content: "----- Message Text -----",
            style: Style.new(reverse: true),
          )
          append separator

          # No explicit height: the `VBox` hands it the leftover space, so it
          # fills everything below the separator (the old `bottom: 0` behavior).
          body = Widget::PlainTextEdit.new(
            window: window,
            input_on_focus: true,
            content: "",
          )
          @body = body
          append body

          wire_vertical_field_navigation
        end

        # Up/Down move between the composer's controls (the Pine convention).
        # Each header field steps to the previous/next control; in the multi-line
        # body, Up only leaves (to the previous control) when the caret is already
        # on the first line — otherwise Up/Down move within the body text.
        private def wire_vertical_field_navigation
          order = focus_order
          order.each_with_index do |w, i|
            prev = i > 0 ? order[i - 1] : nil
            nxt = order[i + 1]?
            if w == body
              w.on(::Crysterm::Event::KeyPress) do |e|
                prev.try(&.focus) if e.key == ::Tput::Key::Up && body_at_top?
              end
            else
              w.on(::Crysterm::Event::KeyPress) do |e|
                case e.key
                when ::Tput::Key::Up   then prev.try &.focus
                when ::Tput::Key::Down then nxt.try &.focus
                end
              end
            end
          end
        end

        # The focusable controls in top-to-bottom order: the header fields then
        # the body.
        private def focus_order : Array(Widget)
          order = [] of Widget
          FIELD_NAMES.each { |n| @fields[n.downcase]?.try { |f| order << f } }
          order << body
          order
        end

        # Whether the body's caret sits on its first (logical) line, so Up should
        # leave the body rather than move within it.
        private def body_at_top? : Bool
          body.value[0, body.cursor_pos].count('\n') == 0
        end

        # Focuses the first header field (To).
        def focus_first
          @fields["to"]?.try &.focus
        end

        # Whether *w* is one of this composer's header input fields (used by a
        # host that wants Enter to advance between fields like Tab, while leaving
        # the multi-line body's Enter to insert a newline).
        def header_field?(w) : Bool
          @fields.each_value.includes? w
        end

        # Focuses the header field named *name* (e.g. `"attchmnt"`), falling back
        # to the first field when there is no such field.
        def focus_field(name : String)
          (@fields[name]? || @fields.first_value?).try &.focus
        end

        # Clears every field and the body.
        def reset
          @fields.each_value &.value = ""
          body.set_content ""
        end

        # Returns the current header values plus the body text, for inspection.
        def values : Hash(String, String)
          h = {} of String => String
          @fields.each { |k, v| h[k] = v.value }
          h["body"] = body.get_text
          h
        end
      end
    end
  end
end
