require "./node"

module Crysterm
  module Widget
    class TextBox < TextArea

      property secret : Bool = false
      property censor : Bool = false
      #property value : String = ""

      def initialize(
        secret = nil,
        censor = nil,
        **textarea
      )
        @scrollable = false

        super **textarea

        secret.try { |v| @secret = v }
        censor.try { |v| @censor = v }
      end

      def set_value(value = nil)
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
            visible = -(width - iwidth - 1)
            val = @value.gsub /\t/, @screen.tabc
            set_content val[visible...]
          end

          _update_cursor
        end
      end

      def submit
        # TODO
        #return unless @__listener
        #@__listener.call '\r', { "name" => "enter" }
      end

    end
  end
end
