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

    @render_flag : Atomic(UInt8) = Atomic.new 0u8
    @render_channel : Channel(Bool) = Channel(Bool).new
    property interval : Float64 = 1/29

    def schedule_render
      _old, succeeded = @render_flag.compare_and_set 0, 1
      if succeeded
        @render_channel.send true
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
      end

      def avg(value)
        @deque.shift if @deque.size == @capacity
        @deque.push value
        @deque.sum // @deque.size
      end
    end

    @rps = Average.new 30
    @dps = Average.new 30
    @fps = Average.new 30

    def render_loop
      loop do
        if @render_channel.receive
          sleep @interval.seconds
        end
        _render
        if @render_flag.lazy_get == 2
          break
        else
          @render_flag.swap 0
        end
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
