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
    # set — but the fallback is *non-materializing*: reading e.g. `#focused`
    # returns `normal` without storing it, so an unset state stays unset
    # (`@focused == nil`).
    #
    # This matters because the CSS cascade snapshots a widget's pristine styles
    # with `#deep_dup` (reading the ivars directly) and folds stateless rules
    # into `normal` plus only the states that are explicitly present. A getter
    # that materialized `@focused = normal` on a mere read would turn that into a
    # *distinct* `normal` copy in the snapshot, which the base fold then skips —
    # so a widget rendered in that state (e.g. a focused `List`) would lose every
    # stateless rule, such as its CSS border. The `own_*?` predicates rely on the
    # same: an unread state must stay `nil`.
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

    # Whether a *distinct* selected style has been materialized, as opposed to
    # lazily falling back to `normal`. Lets a list widget tell an explicit
    # selected-item style (from `selection-*`, a `:selected` rule, or code) apart
    # from the normal-state fallback — only the former should color a selection.
    def own_selected? : Bool
      !@selected.nil?
    end

    # TODO Add each/each_entry iterators

    def initialize(@normal = @normal, @blurred = @blurred, @focused = @focused, @hovered = @hovered, @selected = @selected, @disabled = @disabled)
    end

    # A deep copy: `normal` plus each *explicitly-set* state gets its own
    # independent `Style` (each `#dup` being itself deep — see `Style#dup`).
    # Unset states are left lazy (defaulting to the copy's `normal`), and the
    # ivars are read directly so reading them here does not *materialize* the
    # lazy states on the original. Used by the CSS cascade to snapshot a widget's
    # pristine, pre-CSS styles so every recompute starts clean.
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
