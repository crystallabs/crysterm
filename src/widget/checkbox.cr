require "./abstract_button"
require "../mixin/check_marker"

module Crysterm
  class Widget
    # Checkbox element, modeled after Qt's `QCheckBox`.
    #
    # In addition to the plain checked/unchecked pair it supports a tri-state
    # mode (`#tristate?`), in which an extra *partially checked* (indeterminate)
    # state sits between the two — the equivalent of `Qt::PartiallyChecked`,
    # typically used for a "select all" box whose children are mixed.
    #
    # <!-- widget-examples:capture v1 -->
    # ![CheckBox screenshot](../../tests/widget/checkbox/checkbox.5s.apng)
    # <!-- /widget-examples:capture -->
    class CheckBox < AbstractButton
      # The `[x] label` marker rendering, marker-click hit-test, activate-key
      # toggle, and focus cursor.
      include Mixin::CheckMarker

      # TODO support for changing icons

      # Whether the box is in its partially-checked (indeterminate) state. Only
      # reachable when `#tristate?` (Qt's `Qt::PartiallyChecked`). Read-only —
      # a raw writer would bypass the `invalidate_css`/`Event::StateChanged`
      # transition `#partial`/`#check_state=` run; assign `#check_state=` (or
      # call `#partial`) instead.
      getter? partial : Bool = false

      # Whether a third, partially-checked state participates in toggling, like
      # Qt's `QCheckBox#tristate`.
      property? tristate : Bool = false

      def initialize(checked : Bool = false, tristate : Bool = false, **input)
        super **input

        @tristate = tristate
        setup_marker_control checked, input["content"]?
      end

      # Positional text convenience — Qt's `QCheckBox(text)`. Routed via
      # `content:`, the same label path `#setup_marker_control` already reads;
      # an explicit `content:` in *opts* wins over the positional *text*.
      def initialize(text : String, **opts)
        initialize(**{content: text}.merge(opts))
      end

      def render(with_children = true)
        # `[`/`]` and the state mark resolve CSS-first (`CheckBox::indicator`,
        # with `:checked`/`:indeterminate` addressing the per-state mark), then
        # the registry; the width is stabilized over every reachable state.
        content =
          if tristate?
            marker_line(Glyphs::Role::CheckboxOpen, Glyphs::Role::CheckboxClose, mark_role,
              Glyphs::Role::CheckboxChecked, Glyphs::Role::CheckboxUnchecked, Glyphs::Role::CheckboxPartial)
          else
            marker_line(Glyphs::Role::CheckboxOpen, Glyphs::Role::CheckboxClose, mark_role,
              Glyphs::Role::CheckboxChecked, Glyphs::Role::CheckboxUnchecked)
          end
        set_content content, true
        super false
      end

      # Registry role of the mark between the brackets for the current state:
      # the check mark when checked, a dash when partially checked, a space
      # otherwise.
      private def mark_role : Glyphs::Role
        return Glyphs::Role::CheckboxChecked if checked?
        return Glyphs::Role::CheckboxPartial if partial?
        Glyphs::Role::CheckboxUnchecked
      end

      # Resets the partially-checked state on a check/uncheck transition
      # (`AbstractButton#check`/`#uncheck` hook).
      private def clear_partial : Nil
        @partial = false
      end

      # Current tri-state check state (Qt's `QCheckBox#checkState`), derived
      # from `#checked?`/`#partial?`.
      def check_state : ::Crysterm::CheckState
        return ::Crysterm::CheckState::PartiallyChecked if partial?
        checked? ? ::Crysterm::CheckState::Checked : ::Crysterm::CheckState::Unchecked
      end

      # Sets the tri-state check state (Qt's `QCheckBox#setCheckState`).
      # `Checked`/`Unchecked` route through `#check`/`#uncheck` (both already
      # emit `Event::StateChanged`); `PartiallyChecked` is a no-op unless
      # `#tristate?`, and — matching `#check`/`#uncheck` — a checked→partial
      # move announces the interim `Unchecked` before `PartiallyChecked`, so a
      # listener mirroring `#checked?` never lags the `[-]` marker.
      def check_state=(state : ::Crysterm::CheckState) : ::Crysterm::CheckState
        case state
        in .checked?
          check
        in .unchecked?
          uncheck
        in .partially_checked?
          return state unless tristate?
          return state if partial?
          was_checked = checked?
          @checked = false
          @partial = true
          invalidate_css
          emit Crysterm::Event::StateChanged, ::Crysterm::CheckState::Unchecked if was_checked
          emit Crysterm::Event::StateChanged, ::Crysterm::CheckState::PartiallyChecked
          request_render # repaint the `-` marker
        end
        state
      end

      # Puts the box in its partially-checked (indeterminate) state. No-op unless
      # `#tristate?`. Qt-style shorthand for `self.check_state = PartiallyChecked`.
      def partial
        self.check_state = ::Crysterm::CheckState::PartiallyChecked
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
    end

    # <!-- widget-examples:capture v1 -->
    # ![CheckBox screenshot](../../tests/widget/checkbox/checkbox.5s.apng)
    # <!-- /widget-examples:capture -->
    alias Checkbox = CheckBox
  end
end
