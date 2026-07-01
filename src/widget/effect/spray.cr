require "../box"
require "../../widget_effect_direct"

module Crysterm
  class Widget
    module Effect
      # "Spray" effect: glyphs are shot one after another from a single emitter
      # point and fly outward, each growing as it travels, until they land and
      # fill the widget's whole area. The *order* cells are filled in is a
      # pluggable strategy (`#fill`) — spiral (default), raster scan, radial
      # spread, random, or any caller-supplied ordering.
      #
      # Like `Widget::Effect::Plasma`, it paints straight into the window's cell
      # buffer as packed `Int64` attrs (direct `0xRRGGBB` fg) via `Effect::Direct`,
      # avoiding per-cell `String`s and per-frame tag parsing. Each frame the slot
      # simulation resolves once into two flat `w*h` buffers (glyph and color) in
      # `#advance`, which `#cell` then reads. Self-contained and self-animating;
      # call `#start`/`#stop`.
      #
      # ```
      # # Default: a spiral of dithered DOS bricks (`▒`) filling the box.
      # spray = Widget::Effect::Spray.new parent: window, width: "100%", height: "100%"
      # spray.start
      #
      # # Or spell out text and pick any fill order:
      # spray = Widget::Effect::Spray.new parent: window, width: "100%", height: "100%",
      #   pattern: "CRYSTERM ", fill: :radial
      # ```
      #
      # <!-- widget-examples:capture v1 -->
      # ![Spray screenshot](../../../tests/widget/effect/spray/spray.5s.apng)
      # <!-- /widget-examples:capture -->
      class Spray < Box
        include Effect::Direct

        # A fill strategy: given the area's width and height, returns the order in
        # which cells `{x, y}` are visited (one landed glyph per cell).
        alias FillProc = (Int32, Int32) -> Array(Tuple(Int32, Int32))

        # Cell-visit order. Either a built-in `Symbol` (`:spiral` (default),
        # `:rows`, `:columns`, `:diagonal`, `:radial`, `:random`) or a `FillProc`
        # returning a custom ordering.
        property fill : Symbol | FillProc

        # Text the cells settle on once landed: non-space chars are cycled across
        # the visit order. Defaults to the DOS dithered block `▒` for a solid
        # shaded fill; pass any string to spell it out instead.
        property pattern : String

        # Growth ramp a glyph steps through while in flight, faking a zoom toward
        # the viewer as it flies out of the emitter.
        property grow : Array(String)

        # Emitter point `{x, y}` the glyphs are launched from. `nil` = box centre.
        property origin : Tuple(Int32, Int32)?

        # Frames between successive glyph launches (smaller = denser, faster fill).
        property spacing : Int32

        # Frames a glyph spends in flight from the emitter to its cell.
        property travel : Int32

        # Frames the filled area is held before the cycle restarts (when looping).
        property hold : Int32

        # Whether to restart the whole spray once the area is full and held. When
        # `false`, the effect stops after one fill and runs `#on_complete`.
        property? loop : Bool

        # Colors the pre-launch "charge-up" spark cycles through at the emitter
        # (native `0xRRGGBB` ints).
        property spark_colors : Array(Int32) = [0xff8080, 0x80c0ff]

        # Backwards compatibility: accept `"#rrggbb"`/named color strings.
        def spark_colors=(colors : Array(String))
          @spark_colors = colors.map { |c| Colors.convert(c).to_i32 }
        end

        # Optional color override: `(slot_index, frame, phase) -> 0xRRGGBB`, where
        # *phase* is `:pending`, `:flight`, or `:landed`. `nil` uses the built-in
        # rainbow.
        property color : Proc(Int32, Int32, Symbol, Int32)?

        # Run once, after a non-looping spray has filled the area.
        property on_complete : Proc(Nil)?

        # Per-area state, (re)built lazily whenever the area's size changes (`@cols`
        # / `@rows` are the interior size, owned by `Effect::Direct`).
        @slots = [] of Tuple(Int32, Int32, Char)
        @frame = 0

        # Flat `w*h` per-cell buffers (row-major), filled once per frame in
        # `#advance` and read back in `#cell`. Untouched cells default to a
        # space glyph and `-1` color (widget's default fg).
        @cell_glyph = [] of Char
        @cell_color = [] of Int32

        # Set by `#advance`: `true` once a non-looping spray has filled the area.
        # Read by the shared animation loop via `#done?`.
        @done = false

        def initialize(
          @pattern = "▒",
          @fill = :spiral,
          @grow = [".", "·", ":", "*", "o", "O", "0", "@"],
          @origin = nil,
          @interval = 0.07.seconds,
          @spacing = 1,
          @travel = 12,
          @hold = 28,
          @loop = true,
          spark_colors = [0xff8080, 0x80c0ff],
          @color = nil,
          @on_complete = nil,
          **box,
        )
          self.spark_colors = spark_colors
          super **box
        end

        # The visit order for the built-in (or custom) fill strategy.
        private def fill_cells(w, h) : Array(Tuple(Int32, Int32))
          case f = @fill
          when FillProc then f.call(w, h)
          when :rows    then (0...h).flat_map { |y| (0...w).map { |x| {x, y} } }
          when :columns then (0...w).flat_map { |x| (0...h).map { |y| {x, y} } }
          when :diagonal
            cells = (0...h).flat_map { |y| (0...w).map { |x| {x, y} } }
            cells.sort_by! { |(x, y)| {x + y, x} }
          when :random
            cells = (0...h).flat_map { |y| (0...w).map { |x| {x, y} } }
            cells.shuffle!
          when :radial
            ox, oy = emitter(w, h)
            cells = (0...h).flat_map { |y| (0...w).map { |x| {x, y} } }
            cells.sort_by! { |(x, y)| ((x - ox) ** 2 + (y - oy) ** 2) }
          else
            spiral_cells(w, h)
          end
        end

        # Clockwise spiral over every cell from the top-left corner inward: top row
        # L→R, right border T→B, bottom row R→L, left border B→T, then in one ring.
        private def spiral_cells(w, h) : Array(Tuple(Int32, Int32))
          cells = [] of Tuple(Int32, Int32)
          top, bottom, left, right = 0, h - 1, 0, w - 1
          while top <= bottom && left <= right
            (left..right).each { |x| cells << {x, top} }
            top += 1
            (top..bottom).each { |y| cells << {right, y} }
            right -= 1
            if top <= bottom
              right.downto(left) { |x| cells << {x, bottom} }
              bottom -= 1
            end
            if left <= right
              bottom.downto(top) { |y| cells << {left, y} }
              left += 1
            end
          end
          cells
        end

        # Resolved emitter cell for an area of *w*×*h* (box centre when unset).
        private def emitter(w, h) : Tuple(Int32, Int32)
          @origin || {w // 2, h // 2}
        end

        # (Re)build the landing slots for *w*×*h*: each visited cell paired with the
        # non-space glyph it will settle on, cycled from `pattern`.
        private def reset_slots(w, h)
          letters = @pattern.chars.reject(&.whitespace?)
          letters = ['*'] if letters.empty?
          @slots = fill_cells(w, h).map_with_index do |(x, y), i|
            {x, y, letters[i % letters.size]}
          end
        end

        # Frame at which the last glyph has landed and the area is full.
        private def fill_frame
          @slots.size * @spacing + @travel
        end

        # `Effect::Direct` hook: (re)allocate per-area state when the interior size
        # changes. Builds the landing slots and the two flat `w*h` cell buffers,
        # both cleared to blank glyph / default fg.
        def resize(w, h)
          reset_slots w, h
          @cell_glyph = Array(Char).new(w * h, ' ')
          @cell_color = Array(Int32).new(w * h, -1)
        end

        # `Effect::Direct` hook: resolve one frame of the spray simulation into the
        # flat cell buffers, then advance time. Sets `@done` once a non-looping
        # spray has finished filling.
        def advance(w, h)
          return @done = false if w <= 0 || h <= 0 || @slots.empty?
          recompute w, h
          @frame += 1
          @done = !loop? && @frame > fill_frame
        end

        # Project every slot to its position/glyph/color for the current frame and
        # write it into the flat cell buffers. Cleared first so uncovered cells
        # fall back to blank. No allocation: only overwrites buffers `#resize` sized.
        private def recompute(w, h)
          ox, oy = emitter(w, h)
          cycle = fill_frame + @hold
          f = loop? ? @frame % cycle : @frame

          @cell_glyph.fill(' ')
          @cell_color.fill(-1)

          @slots.each_with_index do |(dx, dy, ch), i|
            launch = i * @spacing
            if f < launch
              gx, gy, gch, phase = ox, oy, '·', :pending
            elsif f < launch + @travel
              p = (f - launch) / @travel.to_f
              gx = (ox + (dx - ox) * p).round.to_i
              gy = (oy + (dy - oy) * p).round.to_i
              gch = @grow[(p * @grow.size).to_i.clamp(0, @grow.size - 1)][0]
              phase = :flight
            else
              gx, gy, gch, phase = dx, dy, ch, :landed
            end
            next unless 0 <= gx < w && 0 <= gy < h
            idx = gy * w + gx
            @cell_glyph[idx] = gch
            @cell_color[idx] = colorize i, phase
          end
        end

        # `Effect::Direct` hook: glyph and packed `0xRRGGBB` fg (or `-1` for widget
        # default) for interior cell `{x, y}`, read from the buffers `#advance` filled.
        def cell(x, y, w, h) : {Char, Int32}
          idx = y * w + x
          {@cell_glyph[idx], @cell_color[idx]}
        end

        # Color (native `0xRRGGBB`) for slot *i* in *phase* at the current frame.
        private def colorize(i, phase) : Int32
          if c = @color
            return c.call(i, @frame, phase)
          end
          case phase
          when :pending then @spark_colors[(@frame // 3) % @spark_colors.size]
          when :flight  then Colors.hsv_i((i * 9 + @frame * 9) % 360)
          else               Colors.hsv_i((i * 9 + @frame * 6) % 360)
          end
        end

        # A non-looping spray finishes once it has filled the area (see `#advance`),
        # at which point the shared animation loop stops and runs `#on_complete`.
        protected def done? : Bool
          @done
        end

        protected def on_done
          @on_complete.try &.call
        end

        # Restart the spray from an empty area on the next frame.
        def restart
          @frame = 0
          @done = false
        end
      end
    end
  end
end
