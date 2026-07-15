require "../progressbar"

module Crysterm
  class Widget
    module Pine
      # The Pine/Alpine "percent-done" progress indicator: a plain, single-row
      # horizontal bar showing completion percentage (Alpine renders this via its
      # `percent_done` display, see `busy.c`).
      #
      # Thin subclass of `Widget::ProgressBar` that only changes defaults to match
      # the Pine look: percentage text shown wrapped in a `[..%]` label, bar one
      # row tall. No border is forced — leave that to CSS. Everything else (value/
      # range model, fill math, keys) is inherited unchanged.
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
          percent : Int32? = nil,
          value : Int32? = nil,
          minimum = 0,
          maximum = 100,
          single_step = 5,
          # Pine defaults: percentage wrapped in a `[..%]` label, single-row bar.
          # Callers can override any of these.
          show_value = true,
          format = "[%p%]",
          height h = 1,
          **input,
        )
          super(
            **input,
            percent: percent,
            value: value,
            minimum: minimum,
            maximum: maximum,
            single_step: single_step,
            show_value: show_value,
            format: format,
            height: h)
        end
      end
    end
  end
end
