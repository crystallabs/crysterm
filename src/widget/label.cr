require "./box"

module Crysterm
  class Widget
    # Basic read-only label
    class Label < Box
      @resizable = true
    end
  end
end
