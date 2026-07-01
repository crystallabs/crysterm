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

          # Three vertical bands via `VBox`: header, separator, body. Header and
          # separator have fixed heights, so the body (no explicit height) fills
          # the rest. Set the ivar directly (not `self.layout=`) so it's in place
          # before children are appended below.
          @layout = Crysterm::Layout::VBox.new

          label_style = Style.new bold: true

          # Two-column form: fixed 10-wide label column (no gap, matching the old
          # `left: 10` field origin), field column fills the rest. `Form` pairs
          # appended children (label, field, label, field, …) into rows.
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
            # "submit-and-return": don't rewind focus on read completion, and turn
            # the resulting `Submit` into a Tab. The body keeps Enter as a newline
            # (it emits no `Submit`).
            input.rewind_on_done = false
            input.on(::Crysterm::Event::Submit) do
              window.emit ::Crysterm::Event::KeyPress.new('\0', ::Tput::Key::Tab)
            end
            # Up/Down move between fields (not input history) — single-line, no
            # in-field vertical movement to preserve.
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

          # No explicit height: `VBox` hands it the leftover space below the
          # separator (the old `bottom: 0` behavior).
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
        # multi-line body, Up only leaves (to the previous control) when the
        # caret is already on the first line — otherwise it moves within the text.
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

        # Focusable controls, top-to-bottom: header fields then body.
        private def focus_order : Array(Widget)
          order = [] of Widget
          FIELD_NAMES.each { |n| @fields[n.downcase]?.try { |f| order << f } }
          order << body
          order
        end

        # Whether the body's caret sits on its first line, so Up should leave the
        # body rather than move within it.
        private def body_at_top? : Bool
          body.value[0, body.cursor_pos].count('\n') == 0
        end

        # Focuses the first header field (To).
        def focus_first
          @fields["to"]?.try &.focus
        end

        # Whether *w* is one of this composer's header input fields (for a host
        # that wants Enter to advance between fields like Tab, leaving the body's
        # Enter as a newline).
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
