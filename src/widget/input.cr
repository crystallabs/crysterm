require "./node"
require "./box"

module Crysterm
  module Widget
    # Abstract input element
    class Input < Box
      @keyable = true
    end
  end
end
