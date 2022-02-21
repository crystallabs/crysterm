module Crysterm
  class Widget
    # Line element
    class Line < Box
      class_property horizontal_char = '-'
      class_property vertical_char = '|'

      property orientation : Tput::Orientation

      def initialize(*, @orientation = Tput::Orientation::Vertical, char = nil, border = Border.new(type: BorderType::Bg), **box)
        orientation.try { |v| @orientation = v }

        # TODO: Error: double splatting a union (NamedTuple(content: String, keys: Bool) | NamedTuple(content: String, keys: Bool, height: Int32) | NamedTuple(content: String, keys: Bool, width: Int32)) is not yet supported
        #if @orientation.vertical?
        #  box = box.merge(width: 1) unless box["width"]?
        #else
        #  box = box.merge(height: 1) unless box["height"]?
        #end

        super **box, border: border

        # char.try { |v| @style.char = v }
        @style.char = case char
                      when nil
                        @orientation.vertical? ? @@vertical_char : @@horizontal_char
                      else
                        char
                      end
      end
    end
  end
end
