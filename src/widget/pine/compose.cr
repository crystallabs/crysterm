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
      # navigation). Each header field is a `Widget::TextBox`; the body is a
      # `Widget::TextArea`. Values are exposed via `#values` for the demo.
      class Compose < Widget::Box
        # Header field names shown to the left of each input.
        FIELD_NAMES = ["To", "Cc", "Bcc", "Attchmnt", "Subject"]

        # The header input boxes, keyed by lower-cased field name.
        getter fields = {} of String => Widget::TextBox

        # The message-body editor.
        getter! body : Widget::TextArea

        def initialize(**box)
          super **box

          label_style = Style.new bold: true

          FIELD_NAMES.each_with_index do |name, i|
            label = Widget::Box.new(
              screen: screen,
              top: i,
              left: 0,
              width: 10,
              height: 1,
              content: "#{name.ljust(8)}:",
              style: label_style,
            )

            input = Widget::TextBox.new(
              screen: screen,
              top: i,
              left: 10,
              right: 0,
              height: 1,
              content: "",
            )

            @fields[name.downcase] = input
            append label
            append input
          end

          sep_top = FIELD_NAMES.size

          separator = Widget::Box.new(
            screen: screen,
            top: sep_top,
            left: 0,
            width: "100%",
            height: 1,
            content: "----- Message Text -----",
            style: Style.new(reverse: true),
          )
          append separator

          body = Widget::TextArea.new(
            screen: screen,
            top: sep_top + 1,
            left: 0,
            width: "100%",
            bottom: 0,
            input_on_focus: true,
            content: "",
          )
          @body = body
          append body
        end

        # Focuses the first header field (To).
        def focus_first
          @fields["to"]?.try &.focus
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
