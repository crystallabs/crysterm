module Crysterm
  class Widget < ::Crysterm::Object
    # module Style
    # Widget's complete style definition.
    class_property style : Style = Style.new

    def style
      focused? ? (@style.focus || @style) : @style
    end

    setter style : Style
    # end
  end
end
