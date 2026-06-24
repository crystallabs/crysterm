require "./box"

module Crysterm
  class Widget
    # Basic read-only label
    #
    # <!-- widget-examples:capture v1 -->
    # ![Label screenshot](../../examples/widget/label/label-capture5s.apng)
    # <!-- /widget-examples:capture -->
    class Label < Box
      @resizable = true
    end

    alias Text = Label
  end
end
