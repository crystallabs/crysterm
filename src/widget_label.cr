module Crysterm
  class Widget < ::Crysterm::Object
    # module Label
    property? label = false
    property _label : Widget?
    @ev_label_resize : Crysterm::Event::Resize::Wrapper?

    # Sets widget label
    def set_label(text, side = "left")
      # If label exists, we update it and return
      @_label.try do |_label|
        _label.set_content(text)
        if side != "right"
          _label.rleft = 2 + (@border ? -1 : 0)
          _label.position.right = nil
          unless @auto_padding
            _label.rleft = 2
          end
        else
          _label.rright = 2 + (@border ? -1 : 0)
          _label.position.left = nil
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
        style: @style.label,
              # border: true,
        # height: 1
)

      if side != "right"
        _label.rleft = 2 - ileft
      else
        _label.rright = 2 - iright
      end

      _label.label = true

      unless @auto_padding
        if side != "right"
          _label.rleft = 2
        else
          _label.rright = 2
        end
        _label.rtop = 0
      end

      @ev_label_scroll = on Crysterm::Event::Scroll, ->reposition(Crysterm::Event::Scroll)
      @ev_label_resize = on Crysterm::Event::Resize, ->reposition(Crysterm::Event::Resize)
    end

    # Removes widget label
    def remove_label
      return unless @_label
      off ::Crysterm::Event::Scroll, @ev_label_scroll
      off ::Crysterm::Event::Resize, @ev_label_resize
      @_label.deparent
      @ev_label_scroll = nil
      @ev_label_resize = nil
      @_label = nil
    end
    # end
  end
end
