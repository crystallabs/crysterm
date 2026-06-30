require "./box"

module Crysterm
  class Widget
    # Basic read-only label
    #
    # <!-- widget-examples:capture v1 -->
    # ![Label screenshot](../../tests/widget/label/label.5s.apng)
    # <!-- /widget-examples:capture -->
    class Label < Box
      @resizable = true
    end

    alias Text = Label
  end
end
