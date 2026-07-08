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
      # The `[x] label` / `(*) label` marker rendering, marker-click hit-test,
      # activate-key toggle, and focus cursor — shared with `RadioButton`.
      include Mixin::CheckMarker

      # TODO support for changing icons

      # TODO checkboxes don't have keys enabled by default, so to be
      # navigable via keys, they need `window.enable_keys(checkbox_obj)`.

      # Whether the box is in its partially-checked (indeterminate) state. Only
      # reachable when `#tristate?` (Qt's `Qt::PartiallyChecked`).
      property? partial : Bool = false

      # Whether a third, partially-checked state participates in toggling, like
      # Qt's `QCheckBox#tristate`.
      property? tristate : Bool = false

      def initialize(checked : Bool = false, tristate : Bool = false, **input)
        super **input

        @tristate = tristate
        setup_marker_control checked, input["content"]?
      end

      def render
        # Composed, measured marker (see `Mixin::CheckMarker#marker_line`):
        # `[`/`]` and the state mark resolve CSS-first (`CheckBox::indicator`,
        # with `:checked`/`:indeterminate` addressing the per-state mark),
        # then the registry; the width is stabilized over every reachable state.
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

      # Resets the partially-checked state on a check/uncheck transition. This
      # is the only per-widget delta in `AbstractButton#check`/`#uncheck`, so it
      # is expressed as this hook and the shared transition body lives once (the
      # `checked?`/`partial?` guards there already account for the tri-state).
      private def clear_partial : Nil
        @partial = false
      end

      # Puts the box in its partially-checked (indeterminate) state. No-op unless
      # `#tristate?`.
      def partial
        return unless tristate?
        return if partial?
        was_checked = checked?
        @checked = false
        @partial = true
        @value = false
        invalidate_css
        # A checked→partial transition drops the checked state, so announce it
        # (before `PartialCheck`) — otherwise a listener mirroring `checked?`
        # (`ButtonGroup`, a bound model) keeps believing the box is checked while
        # it renders `[-]`. `#check`/`#uncheck` handle their edges symmetrically.
        emit Crysterm::Event::UnCheck, false if was_checked
        emit Crysterm::Event::PartialCheck, @value
        request_render # repaint the `-` marker
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
