module Crysterm
  class Widget < ::Crysterm::Object
    # module Interaction

    property? interactive = false

    # Is element clickable?
    property? clickable = false

    # Can element receive keyboard input? (Managed internally; use `input` for user-side setting)
    property? keyable = false

    # Is element draggable?
    property? draggable = false

    property? vi : Bool = false

    # Does it accept keyboard input?
    property? input = false

    property? keys : Bool = false
    property? ignore_keys : Bool = false

    # property? clickable = false

    def set_hover(hover_text)
    end

    def remove_hover
    end

    def draggable?
      @_draggable
    end

    def draggable=(draggable : Bool)
      draggable ? enable_drag(draggable) : disable_drag
    end

    def enable_drag(x)
      @_draggable = true
    end

    def disable_drag
      @_draggable = false
    end

    # :nodoc:
    # no-op in this place
    def _update_cursor(arg)
    end
    # end
  end
end
