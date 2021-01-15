require "./node"

module Crysterm
  class TextBox < TextArea

    def initialize(
      @secret=false,
      @censor=false,
      **textarea
    )
      @scrollable = false

      super **textarea
    end

    def _listener(e)
      case e.key
      when Tput::Key::Return
        # TODO
        #_done nil, @value
      else
        @value = @value + e.char
      end
    end

    def set_value(value=nil)
      value ||= @value

      if @_value != value
        value = value.gsub /\n/, ""
        @value = value
        @_value = value

        if @secret
          set_content ""
        elsif @censor
          set_content "*" * value.size
        else
          visible = -(@width - iwidth - 1)
          val = @value.gsub /\t/, @screen.tabc
          set_content val[...visible]
        end

        _update_cursor
      end
    end

  end
end
