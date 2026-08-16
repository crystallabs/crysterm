module Crysterm
  # Class holding different styles, depending on widget state.
  class Styles
    DEFAULT = new # Default styles for all widgets

    # Returns a copy of the default styles. Must be a `deep_dup`: with a
    # shallow copy every widget would share the `DEFAULT` per-state `Style`
    # objects, so one widget's in-place state edit (`hide`/`show` writing
    # `visible`, a `styles.focused.bg = ...`) would bleed into every other
    # widget — and into `DEFAULT` itself.
    def self.default
      DEFAULT.deep_dup
    end

    property normal : Style = Style.new

    # The non-`normal` slots. Internal reads (`#[]`, `own_*?`, the CSS
    # cascade) treat a `nil` ivar as "state never set" and fall back to
    # `normal` without materializing — that must hold so a lazily-falling-back
    # state keeps seeing every stateless rule folded into `normal`. The public
    # named getters below are the one exception: they materialize.
    @focused : Style?
    @hovered : Style?
    @selected : Style?
    @disabled : Style?
    @checked : Style?

    # `checked` is a per-*property* slot, not a `WidgetState` member: a
    # checked control can simultaneously be focused/hovered, and the CSS side
    # addresses it as the `[checked]` attribute rather than a state class. It
    # styles a checked control at the programmatic floor; an explicitly-set
    # `WidgetState` slot (e.g. `selected`) still wins over it.
    {% for state in %w[focused hovered selected disabled checked] %}
      # Copy-on-write: materializes an own `{{ state.id }}` style (an
      # independent dup of `normal`) on first access, so
      # `styles.{{ state.id }}.bg = ...` edits that state instead of silently
      # mutating `normal`. Fallback-following readers (render paths, the
      # cascade) use `#[]`/`own_{{ state.id }}?`, which never materialize.
      def {{ state.id }} : Style
        @{{ state.id }} ||= normal.dup
      end

      def {{ state.id }}=(@{{ state.id }} : Style)
      end
    {% end %}

    # Whether a distinct style was explicitly set for *state*, as opposed to
    # falling back to `normal`. Only an explicitly-set state style should color
    # e.g. a selection or a focus highlight.
    {% for state in %w[focused hovered selected disabled checked] %}
      def own_{{ state.id }}? : Bool
        !@{{ state.id }}.nil?
      end
    {% end %}

    # The `Style` slot for *state*, falling back to `normal` when unset —
    # without materializing the slot (unlike the named getters).
    def [](state : WidgetState) : Style
      case state
      in .normal?   then normal
      in .focused?  then @focused || normal
      in .hovered?  then @hovered || normal
      in .selected? then @selected || normal
      in .disabled? then @disabled || normal
      end
    end

    # Whether an own style is set for *state* (`normal` counts as always set).
    def own?(state : WidgetState) : Bool
      case state
      in .normal?   then true
      in .focused?  then own_focused?
      in .hovered?  then own_hovered?
      in .selected? then own_selected?
      in .disabled? then own_disabled?
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
      @checked.try &.visible = value
    end

    # Yields each explicitly-set per-state `Style` — always `normal`, then any of
    # `focused`/`hovered`/`selected`/`disabled` that were set. Unset states resolve
    # to `normal` at lookup time and so are not yielded (matching how `#deep_dup`
    # and `#visible=` walk the set states).
    def each(& : Style ->) : Nil
      yield normal
      @focused.try { |s| yield s }
      @hovered.try { |s| yield s }
      @selected.try { |s| yield s }
      @disabled.try { |s| yield s }
      @checked.try { |s| yield s }
    end

    # :ditto: — paired with the owning `WidgetState`. The `checked` slot is not
    # a `WidgetState` and is not yielded here.
    def each_entry(& : (WidgetState, Style) ->) : Nil
      yield WidgetState::Normal, normal
      @focused.try { |s| yield WidgetState::Focused, s }
      @hovered.try { |s| yield WidgetState::Hovered, s }
      @selected.try { |s| yield WidgetState::Selected, s }
      @disabled.try { |s| yield WidgetState::Disabled, s }
    end

    def initialize(@normal = @normal, @focused = @focused, @hovered = @hovered, @selected = @selected, @disabled = @disabled, @checked = @checked)
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
      @checked.try { |style| copy.checked = style.dup }
      copy
    end
  end
end
