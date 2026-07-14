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

    # The non-`normal` states lazily fall back to `normal` when not explicitly
    # set — but non-materializing: reading e.g. `#focused` returns `normal`
    # without storing it, so an unset state stays `nil`.
    #
    # This matters because the CSS cascade snapshots a widget's pristine styles
    # with `#deep_dup` (reading ivars directly) and folds stateless rules into
    # `normal` plus only the explicitly-present states. A getter that
    # materialized `@focused = normal` on read would make the snapshot see a
    # distinct `normal` copy, which the base fold then skips — so a widget
    # rendered in that state (e.g. a focused `List`) would lose every stateless
    # rule, like its CSS border. `own_*?` relies on the same: an unread state
    # must stay `nil`.
    @blurred : Style?
    @focused : Style?
    @hovered : Style?
    @selected : Style?
    @disabled : Style?

    {% for state in %w[blurred focused hovered selected disabled] %}
      def {{state.id}} : Style
        @{{state.id}} || normal
      end

      def {{state.id}}=(@{{state.id}} : Style)
      end
    {% end %}

    # Whether a distinct selected style has been materialized, as opposed to
    # lazily falling back to `normal`. Lets a list widget tell an explicit
    # selected-item style (from `selection-*`, a `:selected` rule, or code) apart
    # from the fallback — only the former should color a selection.
    def own_selected? : Bool
      !@selected.nil?
    end

    # The `Style` slot for *state* — the single state→slot map. The non-`normal`
    # accessors lazily fall back to `normal` without materializing (see above).
    def for_state(state : WidgetState) : Style
      case state
      in .normal?   then normal
      in .blurred?  then blurred
      in .focused?  then focused
      in .hovered?  then hovered
      in .selected? then selected
      in .disabled? then disabled
      end
    end

    # Stores *style* into the slot for *state* (the setter side of `#for_state`).
    def set_for_state(state : WidgetState, style : Style) : Nil
      case state
      in .normal?   then self.normal = style
      in .blurred?  then self.blurred = style
      in .focused?  then self.focused = style
      in .hovered?  then self.hovered = style
      in .selected? then self.selected = style
      in .disabled? then self.disabled = style
      end
    end

    # Sets `visible` on `normal` and on every *materialized* (explicitly set)
    # per-state style. Visibility is a widget-level property, not a per-state
    # visual attribute, so `#hide`/`#show` must land on every state the widget
    # can later switch into — otherwise gaining focus/hover/selection would
    # resurrect a stale visibility from that state's own computed style (a
    # widget shown while `:normal` would read back invisible once `:focused`).
    # Unset (`nil`) states need no write: they fall back to `normal`, just set.
    def visible=(value : Bool) : Nil
      normal.visible = value
      @blurred.try &.visible = value
      @focused.try &.visible = value
      @hovered.try &.visible = value
      @selected.try &.visible = value
      @disabled.try &.visible = value
    end

    # TODO Add each/each_entry iterators

    def initialize(@normal = @normal, @blurred = @blurred, @focused = @focused, @hovered = @hovered, @selected = @selected, @disabled = @disabled)
    end

    # A deep copy: `normal` plus each explicitly-set state gets its own
    # independent `Style` (`#dup` is itself deep — see `Style#dup`). Unset states
    # stay lazy (defaulting to the copy's `normal`); ivars are read directly so
    # this doesn't materialize lazy states on the original. Used by the CSS
    # cascade to snapshot a widget's pristine, pre-CSS styles.
    def deep_dup : Styles
      copy = Styles.new(@normal.dup)
      @blurred.try { |style| copy.blurred = style.dup }
      @focused.try { |style| copy.focused = style.dup }
      @hovered.try { |style| copy.hovered = style.dup }
      @selected.try { |style| copy.selected = style.dup }
      @disabled.try { |style| copy.disabled = style.dup }
      copy
    end
  end
end
