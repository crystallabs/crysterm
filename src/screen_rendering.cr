module Crysterm
  class Screen
    # Things related to rendering (setting up memory state for display)
    # module Rendering
    class BorderStop
      property? yes = false
      property xi : Int32?
      property xl : Int32?
    end

    class BorderStops < Hash(Int32, BorderStop)
      def []=(idx : Int32, arg)
        self[idx]? || (self[idx] = BorderStop.new)
        case arg
        when Bool
          self[idx].yes = arg
        else
          self[idx].xi = arg.xi
          self[idx].xl = arg.xl
        end
      end
    end

    @render_flag : Atomic(UInt8) = Atomic.new 0u8
    @render_channel : Channel(Bool) = Channel(Bool).new
    @interval : Float64 = 1/29

    def schedule_render
      _old, succeeded = @render_flag.compare_and_set 0, 1
      if succeeded
        @render_channel.send true
      end
    end

    class Average < Deque(Int32)
      def avg(value)
        shift if size == @capacity
        push value
        sum // size
      end
    end

    @rps = Average.new 30
    @dps = Average.new 30
    @fps = Average.new 30

    def render_loop
      loop do
        if @render_channel.receive
          sleep @interval
        end
        _render
        if @render_flag.lazy_get == 2
          break
        else
          @render_flag.swap 0
        end
      end
    end

    property _border_stops = {} of Int32 => Bool

    # Rendering optimizations.
    property optimization : OptimizationFlag = OptimizationFlag::None

    # XXX move somewhere else?
    # Default cell attribute
    property default_attr : Int32 = ((0 << 18) | (0x1ff << 9)) | 0x1ff

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

    def _dock_borders
      lines = @lines
      stops = @_border_stops
      # i
      # y
      # x
      # ch

      # D O:
      # keys, stop
      # keys = Object.keys(this._borderStops)
      #   .map(function(k) { return +k; })
      #   .sort(function(a, b) { return a - b; })
      #
      # for (i = 0; i < keys.length; i++)
      #   y = keys[i]
      #   if (!lines[y]) continue
      #   stop = this._borderStops[y]
      #   for (x = stop.xi; x < stop.xl; x++)

      stops = stops.keys.map(&.to_i).sort { |a, b| a - b }

      stops.each do |y|
        if (!lines[y]?)
          next
        end
        awidth.times do |x|
          ch = lines[y][x].char
          if @angles[ch]?
            lines[y][x].char = _get_angle lines, x, y
            lines[y].dirty = true
          end
        end
      end
    end

    # Delayed render (user render)
    def render
      schedule_render
    end

    # Real render
    def _render # (draw = true) #@@auto_draw)
      t1 = Time.monotonic

      emit Crysterm::Event::PreRender

      @_border_stops.clear

      # TODO: Possibly get rid of .dirty altogether.
      # TODO: Could possibly drop .dirty and just clear the `lines` buffer every
      # time before a screen.render. This way clearRegion doesn't have to be
      # called in arbitrary places for the sake of clearing a spot where an
      # element used to be (e.g. when an element moves or is hidden). There could
      # be some overhead though.
      # screen.clearRegion(0, this.cols, 0, this.rows);
      @_ci = 0
      @children.each do |el|
        el.index = @_ci
        @_ci += 1
        # D O:
        # el._rendering = true
        el.render
        # D O:
        # el._rendering = false
      end
      @_ci = -1

      # if (@display.dock_borders?) # XXX why we do @display here? Can we do without?
      if @dock_borders
        _dock_borders
      end

      t2 = Time.monotonic

      # draw 0, @lines.size - 1 if draw
      # self.draw if draw
      draw

      # XXX
      # Workaround to deal with cursor pos before the screen
      # has rendered and lpos is not reliable (stale).
      # Only some elements have this function; for others it's a noop.
      focused.try { |focused_widget|
        focused_widget._update_cursor(true)
        focused_widget.emit(Crysterm::Event::Focus)
      }

      @renders += 1

      emit Crysterm::Event::Rendered

      t3 = Time.monotonic

      if pos = @show_fps
        # { rps, dps, fps }
        ps = {1//(t2 - t1).total_seconds, 1//(t3 - t2).total_seconds, 1//(t3 - t1).total_seconds}

        tput.save_cursor
        tput.pos pos
        tput._print { |io| io << "R/D/FPS: " << ps[0] << '/' << ps[1] << '/' << ps[2] }
        if @show_avg
          tput._print { |io| io << " (" << @rps.avg(ps[0]) << '/' << @dps.avg(ps[1]) << '/' << @fps.avg(ps[2]) << ')' }
        end
        tput.restore_cursor
      end
    end
    # end
  end
end
