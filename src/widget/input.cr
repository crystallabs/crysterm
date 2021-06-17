require "./box"

module Crysterm
  class Widget
    # Abstract input element
    class Input < Box
      @input = true
    end
  end
end
