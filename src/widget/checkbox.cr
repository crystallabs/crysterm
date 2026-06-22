require "./input"

module Crysterm
  class Widget
    # Checkbox element, modeled after Qt's `QCheckBox`.
    #
    # In addition to the plain checked/unchecked pair it supports a tri-state
    # mode (`#tristate?`), in which an extra *partially checked* (indeterminate)
    # state sits between the two — the equivalent of `Qt::PartiallyChecked`,
    # typically used for a "select all" box whose children are mixed.
    class CheckBox < Input
      include EventHandler

      # TODO support for changing icons

      # TODO checkboxes don't have keys enabled by default, so to be
      # navigable via keys, they need `screen.enable_keys(checkbox_obj)`.

      property? checked : Bool = false

      # Whether the box is in its partially-checked (indeterminate) state. Only
      # reachable when `#tristate?` (Qt's `Qt::PartiallyChecked`).
      property? partial : Bool = false

      # Whether a third, partially-checked state participates in toggling, like
      # Qt's `QCheckBox#tristate`.
      property? tristate : Bool = false

      property value : Bool = false
      property text : String = ""

      def initialize(@checked : Bool = false, tristate : Bool = false, **input)
        super **input

        @tristate = tristate
        @value = @checked

        input["content"]?.try do |c|
          @text = c
        end

        handle Crysterm::Event::KeyPress
        handle Crysterm::Event::Focus
        handle Crysterm::Event::Blur

        # Toggle only when the `[ ]`/`( )` marker itself is clicked, not the text
        # label. Uses `Mouse` (not `Click`) because only it carries coordinates;
        # the marker is the three glyphs at the start of the content.
        on(Crysterm::Event::Mouse) do |e|
          next unless e.action.down?
          marker_start = aleft + ileft
          if e.x >= marker_start && e.x < marker_start + 3
            toggle
            request_render
            e.accept
          end
        end
      end

      def render
        set_content selectable_content('[', ']', mark_char), true
        super false
      end

      # Glyph shown between the brackets for the current state: the check mark
      # when checked, a dash when partially checked, a space otherwise.
      private def mark_char : Char
        return 'x' if checked?
        return '-' if partial?
        ' '
      end

      # Builds the `<open><glyph><close> text` line for a selectable control.
      # Shared with `RadioButton`, which passes `(`/`)` and its own glyph.
      private def selectable_content(open : Char, close : Char, glyph : Char) : String
        String.build do |s|
          s << open << glyph << close << ' ' << @text
        end
      end

      def check
        return if checked? && !partial?
        @checked = true
        @partial = false
        @value = true
        emit Crysterm::Event::Check, @value
      end

      def uncheck
        return if !checked? && !partial?
        @checked = false
        @partial = false
        @value = false
        emit Crysterm::Event::UnCheck, @value
      end

      # Puts the box in its partially-checked (indeterminate) state. No-op unless
      # `#tristate?`.
      def partial
        return unless tristate?
        return if partial?
        @checked = false
        @partial = true
        @value = false
        emit Crysterm::Event::PartialCheck, @value
      end

      # Cycles to the next state. With `#tristate?` the order matches Qt:
      # unchecked → partially checked → checked → unchecked. Otherwise it just
      # flips checked/unchecked.
      def toggle
        if tristate?
          if checked?
            uncheck
          elsif partial?
            check
          else
            partial
          end
        else
          checked? ? uncheck : check
        end
      end

      def on_keypress(e)
        if e.activates?
          e.accept
          toggle
          request_render
        end
      end

      def on_focus(e)
        return unless lpos = @lpos
        screen?.try do |s|
          s.tput.lsave_cursor self.hash
          s.tput.cursor_pos lpos.yi + itop, lpos.xi + 1 + ileft
          # s.show_cursor # XXX
        end
      end

      def on_blur(e)
        screen?.try do |s|
          s.tput.lrestore_cursor self.hash, true
        end
      end
    end

    alias Checkbox = CheckBox
  end
end
