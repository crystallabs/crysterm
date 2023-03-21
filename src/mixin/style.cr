module Crysterm
  module Mixin
    module Style
      # Current state of Widget

      property state = WidgetState::Normal

      # List of styles corresponding to different widget states.
      #
      # Only one style, `normal` is initialized by default, others default to it if `nil`.
      property styles : ::Crysterm::Styles = ::Crysterm::Styles.default

      # User may set specific style for this widget
      setter style : ::Crysterm::Style?

      # If specific style is not set, it will depend on current state
      def style : ::Crysterm::Style
        @style.try { |style| return style }

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
