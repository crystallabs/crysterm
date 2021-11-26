module Crysterm
  class Widget < ::Crysterm::Object
    # Label, if present is kind of object title/text appearing in the first
    # line, similar to a label/title in Qt's QFrame.
    # Usually this means you will want the widget to have a padding or border,
    # so that the label gets rendered over the border/padding instead of
    # over the widget content.

    # Is label to be displayed or not?
    property? label = false

    # Widget implementing the label. If unspecified and label it set,
    # we create a plain box. One can set this property to implement
    # a different label widget.
    property _label : Widget?

    # Holder for event which will trigger on resize, to adjust the label
    @ev_label_resize : Crysterm::Event::Resize::Wrapper?

    # Sets or clears label text
    def label=(text)
      label ? set_label(text) : remove_label
    end

    # Sets widget label. Can be positioned "left" (default) or "right"
    def set_label(text, side = "left")
      # If label widget exists, we update it and return
      @_label.try do |_label|
        _label.set_content(text)
        if side != "right"
          _label.rleft = 2 + (@border ? -1 : 0)
          _label.right = nil
          unless @auto_padding
            _label.rleft = 2
          end
        else
          _label.rright = 2 + (@border ? -1 : 0)
          _label.left = nil
          unless @auto_padding
            _label.rright = 2
          end
        end
        return
      end

      # Or if it doesn't exist, we create it
      @_label = _label = Widget::Box.new(
        parent: self,
        content: text,
        top: -itop,
        parse_tags: @parse_tags,
        resizable: true,
        style: @style.label # border: true, # height: 1
      )

      if side != "right"
        _label.rleft = 2 - ileft
      else
        _label.rright = 2 - iright
      end

      # XXX Can this be removed or implemented in a different way?
      _label.label = true

      unless @auto_padding
        if side != "right"
          _label.rleft = 2
        else
          _label.rright = 2
        end
        _label.rtop = 0
      end

      @ev_label_scroll = on Crysterm::Event::Scroll, ->reposition_label(Crysterm::Event::Scroll)
      @ev_label_resize = on Crysterm::Event::Resize, ->reposition_label(Crysterm::Event::Resize)
    end

    # Repositions label to the right place. Usually called from resize event
    def reposition_label(event = nil)
      @_label.try do |_label|
        _label.rtop = @child_base - itop
        unless @auto_padding
          _label.rtop = @child_base
        end
        screen.render
      end
    end

    # Removes widget label
    def remove_label
      return unless @_label
      off ::Crysterm::Event::Scroll, @ev_label_scroll
      off ::Crysterm::Event::Resize, @ev_label_resize
      @_label.remove_parent
      @ev_label_scroll = nil
      @ev_label_resize = nil
      @_label = nil
    end
  end
end
