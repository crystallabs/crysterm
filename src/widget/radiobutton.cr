require "./abstract_button"
require "../mixin/check_marker"
require "../mixin/exclusive_group"
require "./radioset"

module Crysterm
  class Widget
    # Radio button element, modeled after Qt's `QRadioButton`.
    #
    # Marker rendering and input wiring come from `Mixin::CheckMarker`; this
    # class adds group exclusivity (`#handle_state_changed`) and the check-only `#toggle`.
    #
    # <!-- widget-examples:capture v1 -->
    # ![RadioButton screenshot](../../tests/widget/radiobutton/radiobutton.5s.apng)
    # <!-- /widget-examples:capture -->
    class RadioButton < AbstractButton
      include Mixin::CheckMarker
      include Mixin::ExclusiveGroup

      # The marker glyphs (`( )` / `(*)`) are customizable per Qt's `::indicator`
      # stylesheet convention: a `RadioButton::indicator` rule sets `glyph` /
      # `glyph-open` / `glyph-close` (and `:checked` addresses the checked mark).
      # See `Mixin::CheckMarker#marker_line`, which resolves each piece CSS-first
      # before the glyph registry.

      # Whether activating the already-checked radio may *un*check it, letting the
      # exclusive set become empty. Default `false` — Qt keeps one selected, and
      # `#toggle` only ever checks; set `true` for a real toggle. This is the flag
      # form of Qt's `nextCheckState` seam.
      property? deselectable : Bool = false

      def initialize(checked : Bool = false, deselectable : Bool = false, **input)
        super **input

        @deselectable = deselectable
        setup_marker_control checked, input["content"]?
        handle Crysterm::Event::StateChanged
      end

      # Positional text convenience — Qt's `QRadioButton(text)`. Routed via
      # `content:`, the same label path `#setup_marker_control` already reads;
      # an explicit `content:` in *opts* wins over the positional *text*.
      def initialize(text : String, **opts)
        initialize(**{content: text}.merge(opts))
      end

      # A radio button only ever *checks* itself when toggled, so the containing
      # group's "exactly one checked" invariant holds and Space/Enter/click can't
      # empty it. Overrides `AbstractButton#toggle` (which would uncheck). With
      # `#deselectable?` it becomes a real toggle: activating the checked one
      # unchecks it, leaving the set empty (Qt's non-default behavior).
      def toggle
        if deselectable? && checked?
          uncheck
        else
          check
        end
      end

      def paint(with_children = true)
        # `(`/`)` and the state mark resolve CSS-first (`RadioButton::indicator`,
        # `:checked` addressing the checked mark), then the registry.
        set_content marker_line(Glyphs::Role::RadioOpen, Glyphs::Role::RadioClose,
          checked? ? Glyphs::Role::RadioChecked : Glyphs::Role::RadioUnchecked,
          Glyphs::Role::RadioChecked, Glyphs::Role::RadioUnchecked), true
        super false
      end

      def handle_state_changed(e)
        # Only a transition *into* checked drives exclusivity; ignore uncheck and
        # partial transitions the merged `StateChanged` now also reports.
        return unless e.state.checked?
        # A `ButtonGroup` member defers exclusivity to the group (its own
        # `exclude_peers` already handles it, regardless of layout) — matching
        # Qt, where per-parent autoExclusive applies only to ungrouped buttons.
        return if group
        el = self
        while el && (el = el.parent)
          if el.is_a?(RadioSet) # || el.is_a?(Form)
            break
          end
        end
        el = el || parent

        # Uncheck the sibling radios — only radios, as a `RadioSet` may hold
        # other checkables that this exclusivity must not touch.
        el.try &.each_descendant do |cel|
          exclude_peer cel, self if cel.is_a?(RadioButton)
        end
      end
    end
  end
end
