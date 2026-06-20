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

    @_resize_loop_fiber : Fiber?
    @_resize_handler : ::Crysterm::Event::Resize::Wrapper?

    # Notifies `resize_loop` that the terminal size changed. A capacity of 1
    # is enough: while a redraw is in progress any number of incoming events
    # collapse into a single pending notification.
    @_resize_channel = Channel(Nil).new(1)

    # Signals the resize loop that a terminal resize was observed. Repeated
    # invocations (before the `resize_interval` has elapsed) coalesce, so a
    # burst of resize events results in a single redraw once things settle.
    private def schedule_resize
      # Non-blocking send: if a notification is already pending, drop this one.
      select
      when @_resize_channel.send(nil)
      else
      end
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
    #
    # Waits for resize notifications from `schedule_resize` and, once the
    # terminal has been quiet for `resize_interval`, re-reads the size and
    # triggers a redraw. Debouncing this way ensures the (potentially
    # expensive) redraw runs once per burst of resize events instead of once
    # per event.
    def resize_loop
      loop do
        # Block until at least one resize is requested.
        @_resize_channel.receive
        # Keep draining further resize events, restarting the timer each time,
        # until the terminal has been quiet for `resize_interval`.
        loop do
          select
          when @_resize_channel.receive
            # Another resize arrived; keep waiting for things to settle.
          when timeout(@resize_interval)
            break
          end
        end
        resize
      end
    end
  end
end
