require "./box"

module Crysterm
  class Widget
    # Abstract input element
    class Input < Box
      @keyable = true
    end
  end
end
