require "event_handler"

require "./event"
require "./mixin/instances"
require "./mixin/children"

module Crysterm
  class Screen
    # File related to display's ability to resize

    # Amount of time to wait before redrawing the screen, after the last successive terminal resize event is received.
    #
    # The value used in Qt is 0.3 seconds.
    # The value commonly used in console apps is 0.2 seconds.
    # Yet another choice could be the frame rate, i.e. 1/29 seconds.
    #
    # This ensures the resizing/redrawing is done only once, once resizing is over.
    # To have redraws happen even while resizing is going on, reduce this interval.
    property resize_interval : Time::Span = 0.2.seconds

    @_resize_fiber : Fiber?
    @_resize_handler : ::Crysterm::Event::Resize::Wrapper?

    # Schedules resize fiber to run at now + `@resize_interval`. Repeated invocations
    # (before the interval has elapsed) have a desirable effect of re-starting the timer.
    private def schedule_resize
      @_resize_fiber.try &.timeout(@resize_interval)
    end

    # Re-reads current size of all `Display`s and triggers redraw of all `Screen`s.
    #
    # NOTE There is currently no detection for which `Display` the resize has
    # happened on, so a resize in any one managed display causes an update and
    # redraw of all displays.
    def resize
      self.tput.reset_screen_size
      # # NOTE Tput#screen should have been called `size` or `screen_size`
      emit ::Crysterm::Event::Resize.new tput.screen
    end

    # :nodoc:
    # TODO Will this be affected when we move all GUI actions happening in a single thread?
    def resize_loop
      loop do
        resize
        sleep
      end
    end
  end
end
