module Crysterm
  module Mixin
    # Shared rendering and interaction for the marker-style checkable controls —
    # `Widget::CheckBox` (`[x] label`) and `Widget::RadioButton` (`(*) label`).
    #
    # Both derive `Widget::AbstractButton` directly as siblings (like Qt's
    # `QCheckBox`/`QRadioButton` under `QAbstractButton`, not one inheriting
    # the other). This module holds their common implementation: marker-only
    # click hit-test, activate-key toggle, focus/blur cursor placement over the
    # marker, and the `<open><glyph><close> text` line builder. Differing
    # pieces (glyph set, tri-state, radio group exclusivity) stay per-widget.
    module CheckMarker
      # Sets the checkable base state (`#checkable?`, `#checked?`, `#value`),
      # the initial `#text` from an explicit `content:` (normally
      # `input["content"]?`), and wires marker input via `#setup_check_marker`.
      # Call from `initialize`, after `super`. Shared by `CheckBox` and
      # `RadioButton`; each still handles its own extra constructor args
      # (`tristate`, the radio's `Event::Check` subscription) around this call.
      private def setup_marker_control(checked, content) : Nil
        @checkable = true # a marker control is inherently checkable
        @checked = checked
        @value = checked

        content.try do |c|
          @text = c
        end

        setup_check_marker
      end

      # Wires the activate keys, focus/blur cursor handling, and the marker-click
      # hit-test. Call from `initialize`, after `super`.
      private def setup_check_marker : Nil
        # `KeyPress` is already wired by `AbstractButton#initialize` (activate
        # keys are family-wide); here we add only the marker-specific handlers.
        handle Crysterm::Event::Focus
        handle Crysterm::Event::Blur

        # Toggle only when the `[ ]`/`( )` marker itself is clicked, not the text
        # label. Uses `Mouse` (not `Click`) since only it carries coordinates;
        # the marker is the three glyphs at the start of the first content row.
        on(Crysterm::Event::Mouse) do |e|
          next unless e.action.down?
          # Compute the marker cell from the *painted* position (`@lpos`), not
          # the layout coords (`atop`/`aleft`): inside a scrolled container the
          # painted row is shifted up by the scroll base, and mouse dispatch
          # hit-tests against `@lpos`. Using `atop`/`aleft` made the marker click
          # dead once the container scrolled. Mirrors `on_focus`.
          next unless lpos = @lpos
          marker_start = lpos.xi + ileft
          # Row check needed because `Mouse` fires for clicks anywhere in the
          # widget's rect — without it, a taller control (border/explicit
          # height) would toggle on any row at the marker's column.
          marker_row = lpos.yi + itop
          if e.y == marker_row && e.x >= marker_start && e.x < marker_start + 3
            toggle
            request_render
            e.accept
          end
        end
      end

      # Cached last-built line and the inputs it was built from. The marker
      # controls call `selectable_content` from `#render` every frame, but the
      # line only changes when the glyph (check state) or label text changes, so
      # the `String.build` is memoized against those inputs.
      @_selectable_content : String?
      @_selectable_key : Tuple(Char, Char, Char, String)?

      # Builds the `<open><glyph><close> text` line for a selectable control.
      # Returns a cached string when the open/close/glyph/text inputs are
      # unchanged since the last call (the steady-state per-frame render case),
      # so no allocation happens on repeated identical renders.
      private def selectable_content(open : Char, close : Char, glyph : Char) : String
        key = {open, close, glyph, @text}
        content = @_selectable_content
        if @_selectable_key != key || content.nil?
          @_selectable_key = key
          content = String.build do |s|
            s << open << glyph << close << ' ' << @text
          end
          @_selectable_content = content
        end
        content
      end

      # The marker controls toggle (rather than push) on activation; the shared
      # `AbstractButton#on_keypress` calls this.
      protected def activate
        toggle
        request_render
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
