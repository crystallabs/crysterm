module Crysterm
  module Mixin
    module Style
      # Current state of Widget

      Crystallabs::Helpers::Enums.enum_property state : WidgetState = WidgetState::Normal

      # Re-wrap the generated `state=` setters so that, when an active stylesheet
      # has ancestor-state rules (`Form:focus Button`), a state transition
      # invalidates styling and the cascade re-runs on the next render. Guarded
      # on an actual change to avoid needless restyles (e.g. lists re-asserting an
      # item's state every frame).
      def state=(value : WidgetState) : WidgetState
        return value if @state == value
        # Snapshot the animatable values of the *old* state's style so any CSS
        # `transition` can tween from them to the new state's values.
        prev = transition_from
        @state = value
        screen?.try do |scr|
          if scr.css_dynamic_state?
            scr.restyle_subtree self # ancestor-state rules exist: recascade
          else
            scr.css_node_changed self # otherwise just keep the cached document in sync
          end
        end
        prev.try { |p| apply_style_transitions p }
        value
      end

      def state=(value : ::Crystallabs::Helpers::Enums::Shorthands)
        self.state = ::Crystallabs::Helpers::Enums.from(WidgetState, value)
      end

      # List of styles corresponding to different widget states.
      #
      # Only one style, `normal` is initialized by default, others default to it if `nil`.
      property styles : ::Crysterm::Styles = ::Crysterm::Styles.default

      # Pristine, pre-CSS snapshot of `#styles`, captured lazily the first time
      # the cascade asks for it. Each cascade rebuilds the computed styles from a
      # fresh dup of this snapshot, so removed rules and changed inherited values
      # don't linger (the cascade is otherwise non-destructive — it builds on the
      # *current* styles).
      @css_base_styles : ::Crysterm::Styles?

      # :ditto:
      def css_base_styles : ::Crysterm::Styles
        @css_base_styles ||= styles.deep_dup
      end

      # Drops the pristine snapshot so it is recaptured from the current `#styles`
      # on the next cascade. Call after deliberately changing a widget's
      # programmatic default styles.
      def reset_css_base_styles : Nil
        @css_base_styles = nil
      end

      # User may set specific style for this widget
      setter style : ::Crysterm::Style?

      # The raw inline style (the `@style` override), before any CSS folding.
      # The CSS cascade reads this to fold inline declarations into the computed
      # per-state `@styles` at its own tier.
      def css_inline_style : ::Crysterm::Style?
        @style
      end

      # Set by the CSS cascade once it has computed this widget's `@styles`
      # (folding in any inline `@style`). When set, `#style` returns the computed
      # per-state style rather than short-circuiting to the raw inline `@style`,
      # so author `!important` rules can outrank inline.
      property? css_styled : Bool = false

      # If specific style is not set, it will depend on current state
      def style : ::Crysterm::Style
        # When CSS has computed this widget's styles, the inline `@style` has
        # already been folded into them at the right cascade tier, so return the
        # per-state style. Otherwise inline `@style` (if any) wins wholesale.
        @style.try { |style| return style } unless @css_styled

        case @state
        in .normal?
          @styles.normal
        in .focused?
          @styles.focused
        in .selected?
          @styles.selected
        in .hovered?
          @styles.hovered
        in .blurred?
          @styles.blurred
        in .disabled?
          @styles.disabled
        end
      end

      # Version with keeping @state and @style in sync:
      # getter state = WidgetState::Normal
      # # :ditto:
      # def state=(state : WidgetState)
      #  @state = state
      #  @style = case state
      #           in .normal?
      #             @styles.normal
      #           in .focused?
      #             @styles.focused
      #           in .selected?
      #             @styles.selected
      #           in .hovered?
      #             @styles.hovered
      #           in .blurred?
      #             @styles.blurred
      #           end
      # end
      # Current style being (or to be) applied during rendering.
      # This variable is managed by Crysterm and points to currently valid/active style.
      # Therefore it is kept in sync (modified together) with `Widget#state`.
      # It is a reference to current style, and editing the style through this reference has not been prevented.
      # Thus, editing `style` will edit whatever object's `style` is pointing to.
      # But note: if widget is e.g. in state `focused` but no special style for focus was defined,
      # widget will render use style `normal`. Editing `style` while widget is in that state
      # will then actually edit the state for `normal`, not `focused`.
      # property style : Style # = Style.new # Placeholder

    end
  end
end
