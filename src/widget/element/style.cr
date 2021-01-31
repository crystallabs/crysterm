module Crysterm
  module Widget
    abstract class Element < Node

      class_property style : Style = Style.new

    end
  end
end
