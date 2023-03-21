module Crysterm
  class Widget
    # Label, if present is kind of object title/text appearing in the first
    # line, similar to a label/title in Qt's QFrame.
    # Usually this means you will want the widget to have a padding or border,
    # so that the label gets rendered over the border/padding instead of
    # over the widget content.

    # Widget implementing the label. If label is asked for and no specific
    # widget is set, we create a TextBox with chosen content.. But one can
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
        # parse_tags: @parse_tags,
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
        _label.top = @child_base - itop
        screen.render
      end
    end

    # Removes widget label
    def remove_label
      return unless @_label
      off ::Crysterm::Event::Scroll, @ev_label_scroll
      off ::Crysterm::Event::Resize, @ev_label_resize
      @_label.remove_from_parent
      @ev_label_scroll = nil
      @ev_label_resize = nil
      @_label = nil
    end
  end
end
