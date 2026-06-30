require "../progressbar"

module Crysterm
  class Widget
    module Pine
      # The Pine/Alpine "percent-done" progress indicator: a plain, single-row
      # horizontal bar that shows the completion percentage while a long-running
      # operation is in progress (Alpine renders this via its `percent_done`
      # display, see `busy.c`).
      #
      # This is a thin subclass of `Widget::ProgressBar` that only changes the
      # defaults to match the Pine look: the percentage text is shown, wrapped in
      # a `[..%]` label, and the bar is one row tall. The filled region is drawn
      # with the inherited reverse-video fill, so it is visible without any extra
      # styling. No border is forced — leave that to CSS. Everything else (the
      # value/range model, fill math, keys) is inherited unchanged.
      #
      # ```
      # require "crysterm"
      #
      # Crysterm::Screen.new do |screen|
      #   bar = Crysterm::Widget::Pine::ProgressBar.new \
      #     parent: screen, top: "center", left: "center", width: 40
      #   bar.value = 45
      # end
      # ```
      #
      # <!-- widget-examples:capture v1 -->
      # ![ProgressBar screenshot](../../../tests/widget/pine/progress_bar/progress_bar.5s.apng)
      # <!-- /widget-examples:capture -->
      class ProgressBar < ::Crysterm::Widget::ProgressBar
        def initialize(
          filled : Int32? = nil,
          value : Int32? = nil,
          minimum = 0,
          maximum = 100,
          step = 5,
          # Pine defaults: show the percentage, wrapped in a `[..%]` label, on a
          # single-row bar. Callers can still override any of these.
          show_text = true,
          text_format = "[%p%]",
          height h = 1,
          **input,
        )
          super(
            **input,
            filled: filled,
            value: value,
            minimum: minimum,
            maximum: maximum,
            step: step,
            show_text: show_text,
            text_format: text_format,
            height: h)
        end
      end
    end
  end
end
