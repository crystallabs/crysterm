module Crysterm
  class Widget
    # Label, if present is kind of object title/text appearing in the first
    # line, similar to a label/title in Qt's QFrame.
    # Usually this means you will want the widget to have a padding or border,
    # so that the label gets rendered over the border/padding instead of
    # over the widget content.

    # Widget implementing the label. If label is asked for and no specific
    # widget is set, we create a LineEdit with chosen content.. But one can
    # set this property manually to have a custom/specific label.
    property _label : Widget?

    def _label!
      @_label.not_nil!
    end

    # Holder for event which will trigger on resize, to adjust the label
    @ev_label_resize : Crysterm::Event::Resize::Wrapper?

    # Sets or clears label text
    def label=(text : String?)
      text ? set_label(text) : remove_label
    end

    # Sets widget label. Can be positioned "left" (default) or "right"
    def set_label(text : String, side = "left")
      # If label widget exists, we update it and return
      @_label.try do |_label|
        _label.set_content(text)
        if side != "right"
          # TODO Shouldn't -border.left be border.left, to move it further to the right ?
          _label.left = 2 + (style.border.try { |border| -border.left } || 0)
          _label.right = nil
        else
          _label.right = 2 + (style.border.try { |border| -border.right } || 0)
          _label.left = nil
        end
        return
      end

      # Or if it doesn't exist, we create it
      @_label = _label = Widget::Box.new(
        parent: self,
        content: text,
        top: -itop,
        parse_tags: @parse_tags,
        style: style.label,
        resizable: true,
      )

      if side != "right"
        _label.left = 2 - ileft
      else
        _label.right = 2 - iright
      end

      @ev_label_scroll = on Crysterm::Event::Scroll, ->reposition_label(Crysterm::Event::Scroll)
      @ev_label_resize = on Crysterm::Event::Resize, ->reposition_label(Crysterm::Event::Resize)
    end

    # Repositions label to the right place. Usually called from resize event
    def reposition_label(event = nil)
      @_label.try do |_label|
        new_top = @child_base - itop
        # Only re-render when the label actually moves: this fires on every
        # Scroll and Resize, and resize jitter would otherwise trigger a stream
        # of no-op renders.
        next if _label.top == new_top
        _label.top = new_top
        request_render
      end
    end

    # Re-glues the label to the top inset for the current frame. `set_label`
    # positions the label (`top: -itop`) at *construction* time, but a border
    # supplied by the CSS cascade only lands at render time — so a widget whose
    # border comes from a stylesheet (e.g. `GroupBox`) would otherwise leave its
    # label one row inside the box instead of on the border. Called from
    # `_render` once styles are resolved; cheap (a nil check) for label-less
    # widgets, and a no-op when the position is already correct.
    protected def sync_label_position : Nil
      @_label.try do |_label|
        top = @child_base - itop
        _label.top = top unless _label.top == top
      end
    end

    # Removes widget label
    def remove_label
      return unless @_label
      off ::Crysterm::Event::Scroll, @ev_label_scroll
      off ::Crysterm::Event::Resize, @ev_label_resize
      @_label.try &.remove_from_parent
      @ev_label_scroll = nil
      @ev_label_resize = nil
      @_label = nil
    end
  end
end
