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
      # Move between fields with Tab / Shift-Tab, or Up / Down.
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

          # Header, separator, body; the body has no explicit height, so it takes
          # the leftover space. Assigned to the ivar so it is in place before the
          # children below are appended.
          @layout = Crysterm::Layout::VBox.new

          label_style = Style.new bold: true

          # `Form` pairs appended children (label, field, label, field, …) into rows.
          header = Widget::Box.new(
            window: window,
            height: FIELD_NAMES.size,
            layout: Crysterm::Layout::Form.new(label_width: 10, horizontal_spacing: 0),
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
            # "submit-and-return". The body keeps Enter as a newline.
            input.rewind_on_done = false
            input.on(::Crysterm::Event::Submitted) do
              window.emit ::Crysterm::Event::KeyPress.new('\0', ::Tput::Key::Tab)
            end
            # Up/Down move between fields rather than through input history.
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

          body = Widget::PlainTextEdit.new(
            window: window,
            input_on_focus: true,
            content: "",
          )
          @body = body
          append body

          wire_vertical_field_navigation
        end

        # Up/Down move between the composer's controls (Pine convention). In the
        # body, Up leaves only when the caret is already on the first line.
        private def wire_vertical_field_navigation
          order = focus_order
          order.each_with_index do |w, i|
            prev = i > 0 ? order[i - 1] : nil
            nxt = order[i + 1]?
            if w == body
              w.on(::Crysterm::Event::KeyPress) do |e|
                if e.key == ::Tput::Key::Up && body_at_top?
                  prev.try(&.focus)
                  e.accept
                end
              end
            else
              w.on(::Crysterm::Event::KeyPress) do |e|
                case e.key
                when ::Tput::Key::Up
                  prev.try &.focus
                  e.accept
                when ::Tput::Key::Down
                  nxt.try &.focus
                  e.accept
                end
              end
            end
          end
        end

        # Focusable controls, top-to-bottom: header fields then body.
        private def focus_order : Array(Widget)
          order = [] of Widget
          FIELD_NAMES.each { |n| @fields[n.downcase]?.try { |f| order << f } }
          order << body
          order
        end

        # Whether the body's caret sits on its first line.
        private def body_at_top? : Bool
          body.value[0, body.cursor_pos].count('\n') == 0
        end

        # Focuses the first header field (To).
        def focus_first
          @fields["to"]?.try &.focus
        end

        # Whether *w* is one of this composer's header input fields.
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
          # Clear through the document: `set_content ""` only blanks the display,
          # leaving the document text stale.
          body.value = ""
        end

        # Returns the current header values plus the body text, for inspection.
        def values : Hash(String, String)
          h = {} of String => String
          @fields.each { |k, v| h[k] = v.value }
          h["body"] = body.rendered_text
          h
        end
      end
    end
  end
end
