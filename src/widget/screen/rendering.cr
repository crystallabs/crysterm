module Crysterm
  class Screen < Node
    module Rendering

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

      @_buf = ""
      property _ci = -1

      property _border_stops = {} of Int32 => Bool

      # Attempt to perform CSR optimization on all possible elements,
      # and not just on full-width ones, i.e. those with uniform cells to their sides.
      # This is known to cause flickering with elements that are not full-width, but
      # it is more optimal for terminal rendering.
      property smart_csr : Bool = false

      # Enable CSR on any element within 20 columns of the screen edges on either side.
      # It is faster than smart_csr, but may cause flickering depending on what is on
      # each side of the element.
      property fast_csr : Bool = false

      # Attempt to perform back_color_erase optimizations for terminals that support it.
      # It will also work with terminals that don't support it, but only on lines with
      # the default background color. As it stands with the current implementation,
      # it's uncertain how much terminal performance this adds at the cost of code overhead.
      property use_bce : Bool = false

      # XXX move somewhere else
      # Default cell attribute
      property dattr : Int32 = ((0 << 18) | (0x1ff << 9)) | 0x1ff

      property padding = Padding.new

      # Automatically position child elements with border and padding in mind.
      property auto_padding = true

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
      property? dock_borders

      # Dockable borders will not dock if the colors or attributes are different.
      # This option will allow docking regardless. It may produce odd looking
      # multi-colored borders.
      @ignore_dock_contrast = false

      property lines = Array(Row).new
      property olines = Array(Row).new

      # Width of tabs in elements' content.
      property tab_size : Int32

      getter! tabc : String

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
          width.times do |x|
            ch = lines[y][x].char
            if @angles[ch]?
              lines[y][x].char = _get_angle lines, x, y
              lines[y].dirty = true
            end
          end
        end
      end

      def render
        return if destroyed?

        emit PreRenderEvent

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

        #if (@screen.dock_borders?) # XXX why we do @screen here? Can we do without?
        if @dock_borders
          _dock_borders
        end

        draw 0, @lines.size - 1

        # Workaround to deal with cursor pos before the screen
        # has rendered and lpos is not reliable (stale).
        # Only some element have this functions; for others it's a noop.
        focused.try &._update_cursor(true)

        @renders += 1

        emit RenderEvent
      end
    end
  end
end
