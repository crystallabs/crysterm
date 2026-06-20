module Crysterm
  class Screen
    # Things related to rendering (setting up memory state for display)

    # No flags, default fg, default bg. An `Int64` (see `Crysterm::Attr`).
    DEFAULT_ATTR = Attr.pack(0, Attr::COLOR_DEFAULT, Attr::COLOR_DEFAULT)
    DEFAULT_CHAR = ' '

    # Note: Disabled since nothing uses it.
    # class BorderStop
    #  property? yes = false
    #  property xi : Int32?
    #  property xl : Int32?
    # end

    # Note: Disabled since nothing uses it.
    # class BorderStops < Hash(Int32, BorderStop)
    #  def []=(idx : Int32, arg)
    #    self[idx]? || (self[idx] = BorderStop.new)
    #    case arg
    #    when Bool
    #      self[idx].yes = arg
    #    else
    #      self[idx].xi = arg.xi
    #      self[idx].xl = arg.xl
    #    end
    #  end
    # end

    # ---- Single-threaded rendering model -----------------------------------
    #
    # Crysterm renders on ONE fiber, Qt-style. The render fiber (`render_loop`)
    # is the sole owner of the cell buffer (`@lines`) and the only place widgets
    # are painted to it. Because the default Crystal runtime is single-threaded
    # and fibers are cooperative, the render fiber and the input/handler fibers
    # never run in parallel — they interleave only at yield points — so NO locks
    # are needed on widget state.
    #
    # Coordination is a single capacity-1 channel used as a coalescing
    # "doorbell": `schedule_render` rings it (non-blocking; extra rings while one
    # is already pending are dropped, which batches bursts into one frame), and
    # `render_loop` consumes the ring *before* rendering, so a change made during
    # a render re-rings the doorbell and is picked up by the next frame (no lost
    # updates). The channel is the only cross-fiber primitive and channels are
    # safe even under multi-threading, so `schedule_render`/`post` may be called
    # from any fiber — but everything they hand off still runs on the one render
    # fiber. If you ever offload heavy work to another fiber/thread, mutate
    # widgets via `post` so it happens on the render fiber, not concurrently.

    # Coalescing render doorbell (capacity 1: at most one render pending).
    @render_wakeup = Channel(Nil).new 1

    # Set by `#destroy` to make `render_loop` exit on its next wake-up.
    @render_stop = false

    # Closures queued by other fibers to run *on the render fiber*, applied just
    # before the next render. This is the marshaling boundary (Qt's queued
    # connection / `postEvent`).
    @ui_queue = Channel(Proc(Nil)).new 1024

    # Minimum delay between frames (also the FPS cap, ~29 fps). Kept in seconds.
    property interval : Float64 = 1/29

    # Monotonic time of the last completed render; nil until the first render so
    # that the very first request paints immediately.
    @last_render_at : Time::Instant? = nil

    # Requests a render. Non-blocking and coalescing; safe to call from any
    # fiber. Multiple calls before the frame is produced collapse into one.
    def schedule_render : Nil
      select
      when @render_wakeup.send nil
        # Doorbell rung; a render is now pending.
      else
        # A render is already pending — coalesce (nothing to do).
      end
    end

    # Queues `block` to run on the render fiber just before the next render, then
    # schedules that render. Use this to apply results computed off the render
    # fiber (a background fiber, or a thread under `-Dpreview_mt`) to widgets,
    # keeping ALL widget mutation on the single render fiber — no locks needed.
    def post(&block : Proc(Nil)) : Nil
      @ui_queue.send block
      schedule_render
    end

    # Runs every currently-queued `post` closure on the render fiber. Drains
    # without blocking (stops as soon as the queue is empty).
    private def drain_ui_queue
      loop do
        select
        when job = @ui_queue.receive
          job.call
        else
          break
        end
      end
    end

    # Fixed-size ring buffer that yields the running average of the last
    # `capacity` values pushed into it.
    #
    # This used to subclass `Deque(Int32)`. Subclassing a stdlib generic is
    # deprecated, and—more importantly—it promotes every `Deque(Int32)` in the
    # whole program (including in unrelated shards) to the virtual type
    # `Deque(Int32)+`, which produces confusing compile errors far away from
    # here (same class of problem as issue #30). It now *wraps* a deque instead.
    class Average
      def initialize(@capacity : Int32)
        @deque = Deque(Int32).new @capacity
        # Running sum of the deque's contents, kept in sync on every push/shift
        # so `avg` is O(1) instead of re-summing the whole deque each call.
        @sum = 0
      end

      def avg(value)
        if @deque.size == @capacity
          @sum -= @deque.shift
        end
        @deque.push value
        @sum += value
        @sum // @deque.size
      end
    end

    @rps = Average.new 30
    @dps = Average.new 30
    @fps = Average.new 30

    def render_loop
      loop do
        # Park until a render is requested. Consuming the doorbell *here*, before
        # rendering, is what closes the lost-update window: any `schedule_render`
        # that fires while `_render` runs re-rings it and triggers another frame.
        @render_wakeup.receive
        break if @render_stop # woken by `#destroy` to exit cleanly

        # Apply any posted UI jobs first, on this (the render) fiber.
        drain_ui_queue

        # Trailing throttle: the first request after an idle period renders
        # immediately; back-to-back requests are spaced out to honor `interval`
        # (the FPS cap), without adding latency to an isolated update.
        @last_render_at.try do |last|
          elapsed = Time.instant - last
          frame = interval.seconds
          sleep(frame - elapsed) if elapsed < frame
        end

        _render
        @last_render_at = Time.instant
      end
    end

    # Rows on which line-drawing characters were emitted this frame and which
    # therefore need to be re-evaluated by the docking pass. Populated during
    # rendering by `Widget#register_dock_stops` (for both borders and `Line`
    # widgets) and consumed by `#_dock`. See `Crysterm::Docking`.
    property _dock_stops = {} of Int32 => Bool

    # Rendering optimizations.
    property optimization : OptimizationFlag = OptimizationFlag::None

    # XXX move somewhere else?
    # Default cell attribute
    property default_attr : Int64 = DEFAULT_ATTR

    # XXX move somewhere else?
    # Default cell character
    property default_char : Char = DEFAULT_CHAR

    # Automatically "dock" borders with other elements instead of overlapping,
    # depending on position.
    #     These border-overlapped elements:
    #     ┌─────────┌─────────┐
    #     │ box1    │ box2    │
    #     └─────────└─────────┘
    #     Become:
    #     ┌─────────┬─────────┐
    #     │ box1    │ box2    │
    #     └─────────┴─────────┘
    property? dock_borders : Bool = false

    # Dockable borders will not dock if the colors or attributes are different.
    # This option will allow docking regardless. It may produce odd looking
    # multi-colored borders.
    @dock_contrast = DockContrast::Blend

    property lines = Array(Row).new
    property olines = Array(Row).new

    # Docks (joins) all line-drawing characters that cross or meet on the rows
    # collected in `@_dock_stops` this frame. Delegates the actual work to the
    # reusable `Crysterm::Docking` component, which is shared between border
    # docking and `Line` widget docking.
    def _dock
      Docking.dock @lines, @_dock_stops, awidth, @dock_contrast
    end

    # Delayed render (user render)
    def render
      schedule_render
    end

    # Real render
    def _render # (draw = true) #@@auto_draw)
      t1 = Time.instant

      emit Crysterm::Event::PreRender

      @_dock_stops.clear

      # Reset the in-memory cell buffer to the default attr/char before
      # compositing this frame. Widgets are re-rendered from scratch on every
      # render (see the loop below), so the buffer must start from a clean base.
      #
      # This is required for correct alpha/transparency blending: alpha widgets
      # blend their color into whatever is already in `@lines` (see
      # `Colors.blend` calls in widget_rendering). Without this reset, each frame
      # would blend on top of the previous frame's already-blended value, so a
      # semi-transparent field would creep toward full saturation on every
      # refresh instead of staying constant.
      #
      # This also removes the need to `clear_region` in arbitrary places just to
      # erase a spot where an element used to be (e.g. when it moves or hides).
      # It is cheap on the wire: `clear_region`/`fill_region` only mark a line
      # dirty when a cell actually changes, and `draw` still diffs every cell
      # against `@olines`, so unchanged cells produce no terminal output.
      clear_region 0, awidth, 0, aheight

      @_ci = 0
      @children.each do |el|
        el.index = @_ci
        @_ci += 1
        el.render
      end
      @_ci = -1

      _dock if @dock_borders

      t2 = Time.instant

      draw

      # XXX Workaround to deal with cursor pos before the screen
      # has rendered and lpos is not reliable (stale).
      # Only some elements have this function; for others it's a noop.
      focused.try do |focused_widget|
        focused_widget._update_cursor(true)
        focused_widget.emit(Crysterm::Event::Focus)
      end

      @renders += 1

      emit Crysterm::Event::Rendered

      t3 = Time.instant

      if pos = @show_fps
        ps = {1 // (t2 - t1).total_seconds, 1 // (t3 - t2).total_seconds, 1 // (t3 - t1).total_seconds}

        tput.save_cursor
        tput.pos pos
        tput._print { |io| io << "R/D/FPS: #{ps[0]}/#{ps[1]}/#{ps[2]}" }
        if @show_avg
          tput._print { |io| io << " (#{@rps.avg(ps[0])}/#{@dps.avg(ps[1])}/#{@fps.avg(ps[2])})" }
        end
        tput.restore_cursor
      end
    end

    # TODO Instead of self, this should just return an object which reports the position
    # like LPos. But until screen is always from (0,0) to (height,width) that's not necessary.
    def last_rendered_position
      self
    end
  end
end
