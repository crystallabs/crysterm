module Crysterm
  # Class holding different styles, depending on widget state.
  class Styles
    DEFAULT = new # Default styles for all widgets

    # Returns a copy of the default style
    def self.default
      d = DEFAULT.dup
      d.normal = d.normal.dup
      d
    end

    property normal : Style = Style.new

    # The non-`normal` states fall back to `normal` when unset, without
    # materializing: reading e.g. `#focused` returns `normal` but leaves the
    # ivar `nil`. This must stay non-materializing — the CSS cascade and
    # `own_*?` both treat a `nil` ivar as "state never set", and a state
    # materialized on read would lose every stateless rule folded into `normal`.
    @focused : Style?
    @hovered : Style?
    @selected : Style?
    @disabled : Style?

    {% for state in %w[focused hovered selected disabled] %}
      def {{state.id}} : Style
        @{{state.id}} || normal
      end

      def {{state.id}}=(@{{state.id}} : Style)
      end
    {% end %}

    # Whether a distinct style was explicitly set for *state*, as opposed to
    # falling back to `normal`. Only an explicitly-set state style should color
    # e.g. a selection or a focus highlight.
    {% for state in %w[focused hovered selected disabled] %}
      def own_{{state.id}}? : Bool
        !@{{state.id}}.nil?
      end
    {% end %}

    # The `Style` slot for *state*.
    def [](state : WidgetState) : Style
      case state
      in .normal?   then normal
      in .focused?  then focused
      in .hovered?  then hovered
      in .selected? then selected
      in .disabled? then disabled
      end
    end

    # Stores *style* into the slot for *state*.
    def []=(state : WidgetState, style : Style) : Nil
      case state
      in .normal?   then self.normal = style
      in .focused?  then self.focused = style
      in .hovered?  then self.hovered = style
      in .selected? then self.selected = style
      in .disabled? then self.disabled = style
      end
    end

    # Sets `visible` on `normal` and on every explicitly-set per-state style.
    # Visibility is widget-level, not a per-state attribute, so it must land on
    # every state the widget can later switch into; otherwise gaining focus or
    # hover would resurrect a stale visibility. Unset states need no write, as
    # they fall back to `normal`.
    def visible=(value : Bool) : Nil
      normal.visible = value
      @focused.try &.visible = value
      @hovered.try &.visible = value
      @selected.try &.visible = value
      @disabled.try &.visible = value
    end

    # TODO Add each/each_entry iterators

    def initialize(@normal = @normal, @focused = @focused, @hovered = @hovered, @selected = @selected, @disabled = @disabled)
    end

    # A deep copy: `normal` plus each explicitly-set state gets its own
    # independent `Style`. Unset states stay unset; ivars are read directly so
    # this does not materialize them on the original.
    def deep_dup : Styles
      copy = Styles.new(@normal.dup)
      @focused.try { |style| copy.focused = style.dup }
      @hovered.try { |style| copy.hovered = style.dup }
      @selected.try { |style| copy.selected = style.dup }
      @disabled.try { |style| copy.disabled = style.dup }
      copy
    end
  end
end
