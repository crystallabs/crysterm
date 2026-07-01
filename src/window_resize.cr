require "event_handler"

require "./event"
require "./mixin/instances"
require "./mixin/children"

module Crysterm
  class Window
    # File related to display's ability to resize

    # Debounce interval before redrawing after the last terminal resize event.
    # Qt uses 0.3s, console apps commonly use 0.2s; another option is the frame
    # rate (1/29s). Reduce this to redraw while resizing is still in progress.
    property resize_interval : Time::Span = Config.window_resize_interval

    @_resize_loop_fiber : Fiber?
    @_resize_handler : ::Crysterm::Event::Resize::Wrapper?

    # Notifies `resize_loop` that the terminal size changed. A capacity of 1
    # is enough: while a redraw is in progress any number of incoming events
    # collapse into a single pending notification.
    @_resize_channel = Channel(Nil).new(1)

    # Authoritative new terminal size in cells (`{cols, rows}`) carried by the
    # most recent in-band resize report (DEC 2048), awaiting the debounced
    # `#resize`. `nil` for a SIGWINCH-driven resize, which has no report and must
    # fall back to the `TIOCGWINSZ` ioctl. Set in `#handle_input`, consumed and
    # cleared by `#resize`.
    @pending_inband_size : {Int32, Int32}? = nil

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

    # Re-reads current size of all `Display`s and triggers redraw of all `Window`s.
    #
    # NOTE There is currently no detection for which `Display` the resize has
    # happened on, so a resize in any one managed display causes an update and
    # redraw of all displays.
    def resize
      if size = @pending_inband_size
        @pending_inband_size = nil
        cols, rows = size
        # An in-band resize report (DEC 2048) already delivered the authoritative
        # new size, so trust it directly instead of re-probing via the
        # `reset_screen_size` ioctl (which in-band resize exists to bypass where
        # SIGWINCH/`TIOCGWINSZ` are unreliable). Mirror its bookkeeping (cached
        # size, cursor clamp) so the rest of the stack stays consistent; the
        # report's cell pixel geometry was already applied in `#handle_input`.
        tput.screen.width = cols
        tput.screen.height = rows
        tput._ncoords
        emit ::Crysterm::Event::Resize.new ::Tput::Namespace::Size.new(cols, rows)
      else
        self.tput.reset_screen_size
        # Pick up a changed cell pixel size (e.g. font/zoom change) via the
        # ioctl; safe here since it does no escape-sequence round-trip.
        @screen.refresh_cell_geometry
        # NOTE Tput#screen should have been called `size` or `screen_size`
        emit ::Crysterm::Event::Resize.new tput.screen
      end
    end

    # :nodoc:
    # TODO Will this be affected when we move all GUI actions happening in a single thread?
    #
    # Waits for resize notifications from `schedule_resize` and, once the
    # terminal has been quiet for `resize_interval`, re-reads the size and
    # triggers a redraw. Ensures the (potentially expensive) redraw runs once
    # per burst instead of once per event.
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
