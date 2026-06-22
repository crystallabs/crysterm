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
    property blurred : Style { normal }
    property focused : Style { normal }
    property hovered : Style { normal }
    property selected : Style { normal }
    property disabled : Style { normal }

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
