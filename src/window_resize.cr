require "event_handler"

require "./event"
require "./mixin/instances"
require "./mixin/children"

module Crysterm
  class Window
    # Debounce interval before redrawing after the last terminal resize event.
    # Reduce this to redraw while resizing is still in progress.
    property resize_interval : Time::Span = Config.window_resize_interval

    @_resize_loop_fiber : Fiber?
    @_resize_handler : ::Crysterm::Event::Resize::Wrapper?

    # Set by `#destroy` to make `resize_loop` exit on its next wake-up. Without
    # it the resize fiber loops forever on `@_resize_channel.receive`, pinning
    # the destroyed window and possibly resizing it after teardown.
    @resize_stop = false

    # Notifies `resize_loop` that the terminal size changed. A capacity of 1 is
    # enough: while a redraw is in progress any number of incoming events
    # collapse into a single pending notification.
    @_resize_channel = Channel(Nil).new(1)

    # Authoritative new terminal size in cells (`{cols, rows}`) carried by the
    # most recent in-band resize report (DEC 2048), awaiting the debounced
    # `#refresh_size`. `nil` for a SIGWINCH-driven resize, which has no report
    # and must fall back to the `TIOCGWINSZ` ioctl.
    @pending_inband_size : {Int32, Int32}? = nil

    # Signals the resize loop that a terminal resize was observed. Repeated
    # invocations (before the `resize_interval` has elapsed) coalesce, so a
    # burst of resize events results in a single redraw once things settle.
    private def schedule_resize
      ring @_resize_channel
    end

    # Subscribes to the global (SIGWINCH-driven) `Event::Resize`, debouncing it
    # onto this window's resize loop. The in-band-resize (DEC 2048) path, when
    # active, reports size via the input stream, so the global signal is ignored
    # to avoid double handling.
    private def subscribe_global_resize : ::Crysterm::Event::Resize::Wrapper
      GlobalEvents.on(::Crysterm::Event::Resize) do |_|
        schedule_resize unless in_band_resize_enabled?
      end
    end

    # Re-reads current size and triggers redraw.
    #
    # NOTE There is currently no detection for which terminal window the resize
    # has happened on, so a resize on any managed window causes an update and
    # redraw.
    def refresh_size
      if size = @pending_inband_size
        @pending_inband_size = nil
        cols, rows = size
        # The in-band resize report (DEC 2048) is authoritative, so trust it
        # instead of re-probing via the `TIOCGWINSZ` ioctl that in-band resize
        # exists to bypass. Mirror the ioctl path's bookkeeping (cached size,
        # cursor clamp) to keep the rest of the stack consistent.
        tput.screen.width = cols
        tput.screen.height = rows
        tput._ncoords
        emit ::Crysterm::Event::Resize.new ::Tput::Namespace::Size.new(cols, rows)
      else
        tput.reset_screen_size
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
    # Waits for resize notifications, and once the terminal has been quiet for
    # `resize_interval`, re-reads the size and triggers a redraw. The
    # (potentially expensive) redraw runs once per burst, not once per event.
    protected def resize_loop(generation : Int32 = 0)
      loop do
        # Block until at least one resize is requested.
        @_resize_channel.receive
        # Exit when woken by `#destroy`, or when superseded by a newer loop
        # fiber (`#revive` bumped the generation after this fiber spawned).
        break if @resize_stop || generation != @loop_generation
        # Keep draining further resize events, restarting the timer each time,
        # until the terminal has been quiet for `resize_interval`.
        loop do
          select
          when @_resize_channel.receive
            break if @resize_stop || generation != @loop_generation
            # Another resize arrived; keep waiting for things to settle.
          when timeout(@resize_interval)
            break
          end
        end
        break if @resize_stop || generation != @loop_generation
        refresh_size
      end
    end
  end
end
