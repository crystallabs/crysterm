module Crysterm
  module Mixin
    # Shared rendering and interaction for the marker-style checkable controls —
    # `Widget::CheckBox` (`[x] label`) and `Widget::RadioButton` (`(*) label`).
    #
    # Both derive `Widget::AbstractButton` *directly* (siblings, exactly as Qt
    # makes `QCheckBox` and `QRadioButton` siblings under `QAbstractButton`,
    # rather than one inheriting the other). This module is the implementation
    # detail they have in common: the marker-only click hit-test, the activate
    # key toggle, the focus/blur cursor placement over the marker, and the
    # `<open><glyph><close> text` line builder. The differing pieces (the glyph
    # set, tri-state, the radio group exclusivity) stay in each widget.
    module CheckMarker
      # Wires the activate keys, focus/blur cursor handling, and the marker-click
      # hit-test. Call from `initialize`, after `super`.
      private def setup_check_marker : Nil
        handle Crysterm::Event::KeyPress
        handle Crysterm::Event::Focus
        handle Crysterm::Event::Blur

        # Toggle only when the `[ ]`/`( )` marker itself is clicked, not the text
        # label. Uses `Mouse` (not `Click`) because only it carries coordinates;
        # the marker is the three glyphs at the start of the *first* content row.
        on(Crysterm::Event::Mouse) do |e|
          next unless e.action.down?
          marker_start = aleft + ileft
          # The marker lives on the first content row only. The `Mouse` event
          # fires for a click anywhere inside the widget's rect, so without the
          # row check a control taller than one line (one with a border, or an
          # explicit `height`) toggled whenever its marker *column* was clicked
          # on any row — e.g. the blank line below a bordered checkbox's marker.
          marker_row = atop + itop
          if e.y == marker_row && e.x >= marker_start && e.x < marker_start + 3
            toggle
            request_render
            e.accept
          end
        end
      end

      # Builds the `<open><glyph><close> text` line for a selectable control.
      private def selectable_content(open : Char, close : Char, glyph : Char) : String
        String.build do |s|
          s << open << glyph << close << ' ' << @text
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
        window?.try do |s|
          s.tput.lsave_cursor self.hash
          s.tput.cursor_pos lpos.yi + itop, lpos.xi + 1 + ileft
          # s.show_cursor # XXX
        end
      end

      def on_blur(e)
        window?.try do |s|
          s.tput.lrestore_cursor self.hash, true
        end
      end
    end
  end
end
