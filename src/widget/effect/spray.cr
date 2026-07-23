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
      # Paints straight into the window's cell buffer as packed `Int64` attrs
      # (direct `0xRRGGBB` fg), avoiding per-cell `String`s and per-frame tag
      # parsing. Each frame the slot simulation resolves once into two flat `w*h`
      # buffers (glyph and color) in `#advance`, which `#cell` then reads.
      # Self-contained and self-animating; call `#start`/`#stop`.
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

        # Built-in cell-visit orders (see `FillProc` for a custom ordering).
        enum Fill
          Spiral
          Rows
          Columns
          Diagonal
          Radial
          Random
        end

        # Cell-visit order. Either a built-in `Fill` (`Fill::Spiral` (default),
        # `Fill::Rows`, `Fill::Columns`, `Fill::Diagonal`, `Fill::Radial`,
        # `Fill::Random`) or a `FillProc` returning a custom ordering.
        getter fill : Fill | FillProc

        # :ditto:
        # Rebuilds the landing slots immediately when the area size is known, so
        # a mid-run reassignment reorders the spray live (slots are otherwise
        # rebuilt only on a size change, leaving the change queued until an
        # unrelated resize).
        def fill=(value : Fill | FillProc) : Fill | FillProc
          return value if value == @fill
          @fill = value
          reset_slots(@cols, @rows) if @cols > 0 && @rows > 0
          mark_dirty
          value
        end

        # Text the cells settle on once landed: non-space chars are cycled across
        # the visit order. Defaults to the DOS dithered block `▒` for a solid
        # shaded fill; pass any string to spell it out instead.
        getter pattern : String

        # :ditto:
        # Remaps the new glyphs onto the existing visit order in place, so a
        # mid-run reassignment respells the spray live — without reshuffling a
        # `Fill::Random` layout the way a full slot rebuild would.
        def pattern=(value : String) : String
          return value if value == @pattern
          @pattern = value
          unless @slots.empty?
            letters = pattern_letters
            @slots = @slots.map_with_index do |(x, y, _), i|
              {x, y, letters[i % letters.size]}
            end
          end
          mark_dirty
          value
        end

        # Default growth ramp; also the fallback if an empty ramp is assigned.
        DEFAULT_GROW = [".", "·", ":", "*", "o", "O", "0", "@"]

        # Growth ramp a glyph steps through while in flight, faking a zoom toward
        # the viewer as it flies out of the emitter.
        #
        # An empty ramp — or one that only *contains* empty strings — would crash
        # the render fiber (`recompute` reads `@grow[…][0]`, and `""[0]` raises
        # `IndexError`). Drop empty entries and fall back to the default if nothing
        # usable remains.
        # ameba:disable Lint/UselessAssign
        nonempty_property grow : Array(String) = DEFAULT_GROW, reject_empty_entries: true

        # Emitter point `{x, y}` the glyphs are launched from. `nil` = box centre.
        getter origin : Tuple(Int32, Int32)?

        # :ditto:
        # Only a `Fill::Radial` visit order depends on the emitter (it is sorted
        # by distance from it at slot-build time), so re-sort it around the new
        # origin; other orders are origin-independent and keep their slots (no
        # gratuitous `Fill::Random` reshuffle). Flight trajectories and the
        # pending spark read `origin` live each frame either way.
        def origin=(value : Tuple(Int32, Int32)?) : Tuple(Int32, Int32)?
          return value if value == @origin
          @origin = value
          if @fill.as?(Fill).try(&.radial?) && @cols > 0 && @rows > 0
            reset_slots(@cols, @rows)
          end
          mark_dirty
          value
        end

        # Frames between successive glyph launches (smaller = denser, faster fill).
        property spacing : Int32

        # Frames a glyph spends in flight from the emitter to its cell.
        property travel : Int32

        # Frames the filled area is held before the cycle restarts (when looping).
        property hold : Int32

        # Whether to restart the whole spray once the area is full and held. When
        # `false`, the effect stops after one fill and runs `#on_complete`.
        property? repeat : Bool

        # Default spark colors; also the fallback if an empty list is assigned.
        DEFAULT_SPARK_COLORS = [0xff8080, 0x80c0ff]

        # Colors the pre-launch "charge-up" spark cycles through at the emitter
        # (native `0xRRGGBB` ints).
        #
        # An empty list would crash the render fiber (`% @spark_colors.size` is a
        # division by zero), so an empty assignment is rejected in favour of the
        # default.
        # ameba:disable Lint/UselessAssign
        nonempty_property spark_colors : Array(Int32) = DEFAULT_SPARK_COLORS

        # Backwards compatibility: accept `"#rrggbb"`/named color strings. Converts
        # to native ints, then routes through the empty-guarded `Int32` setter above.
        def spark_colors=(colors : Array(String))
          self.spark_colors = colors.map { |c| Colors.to_native(c) }
        end

        # A slot's lifecycle phase, passed to a custom `#color` proc.
        enum Phase
          Pending
          Flight
          Landed
        end

        # Optional color override: `(slot_index, frame, phase) -> 0xRRGGBB`, where
        # *phase* is `Phase::Pending`, `Phase::Flight`, or `Phase::Landed`. `nil`
        # uses the built-in rainbow.
        property color : Proc(Int32, Int32, Phase, Int32)?

        # Run once, after a non-looping spray has filled the area.
        property on_complete : Proc(Nil)?

        # Block form of `#on_complete=`: `spray.on_complete { ... }`.
        def on_complete(&block : ->) : Nil
          @on_complete = block
        end

        # Per-area state, (re)built lazily whenever the area's size changes.
        @slots = [] of Tuple(Int32, Int32, Char)
        # Int64 so the multiplications in `#colorize` never wrap, even on an
        # animation left looping for months.
        @frame : Int64 = 0_i64

        # Flat `w*h` per-cell buffers (row-major), filled once per frame in
        # `#advance` and read back in `#cell`. Untouched cells default to a
        # space glyph and `-1` color (widget's default fg).
        @cell_glyph = [] of Char
        @cell_color = [] of Int32

        # `true` once a non-looping spray has filled the area.
        @done = false

        def initialize(
          @pattern = "▒",
          @fill : Fill | FillProc = Fill::Spiral,
          grow = DEFAULT_GROW,
          @origin = nil,
          @interval = 0.07.seconds,
          @spacing = 1,
          @travel = 12,
          @hold = 28,
          @repeat = true,
          spark_colors = DEFAULT_SPARK_COLORS,
          @color = nil,
          @on_complete = nil,
          **box,
        )
          self.grow = grow # reject empty in favour of the default
          self.spark_colors = spark_colors
          super **box
        end

        # The visit order for the built-in (or custom) fill strategy.
        private def fill_cells(w, h) : Array(Tuple(Int32, Int32))
          case f = @fill
          in FillProc
            f.call(w, h)
          in Fill
            case f
            in .spiral?
              spiral_cells(w, h)
            in .rows?
              all_cells(w, h)
            in .columns?
              (0...w).flat_map { |x| (0...h).map { |y| {x, y} } }
            in .diagonal?
              cells = all_cells(w, h)
              cells.sort_by! { |(x, y)| {x + y, x} }
            in .random?
              cells = all_cells(w, h)
              cells.shuffle!
            in .radial?
              ox, oy = emitter(w, h)
              cells = all_cells(w, h)
              cells.sort_by! { |(x, y)| ((x - ox) ** 2 + (y - oy) ** 2) }
            end
          end
        end

        # Every `{x, y}` cell of a *w*×*h* area in row-major order (top row
        # L→R, then down). The unsorted base several fill strategies then sort
        # or shuffle; `Fill::Columns` needs column-major so it builds its own.
        private def all_cells(w, h) : Array(Tuple(Int32, Int32))
          (0...h).flat_map { |y| (0...w).map { |x| {x, y} } }
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

        # The non-space glyphs of `pattern`, cycled across the visit order; a
        # whitespace-only (or empty) pattern falls back to `'*'` so the slot set
        # is always fillable.
        private def pattern_letters : Array(Char)
          letters = @pattern.chars.reject(&.whitespace?)
          letters.empty? ? ['*'] : letters
        end

        # (Re)build the landing slots for *w*×*h*: each visited cell paired with the
        # non-space glyph it will settle on, cycled from `pattern`.
        private def reset_slots(w, h)
          letters = pattern_letters
          @slots = fill_cells(w, h).map_with_index do |(x, y), i|
            {x, y, letters[i % letters.size]}
          end
        end

        # Frame at which the last glyph has landed and the area is full.
        private def fill_frame
          @slots.size * @spacing + @travel
        end

        # (Re)allocates per-area state when the interior size changes: the landing
        # slots and the two flat `w*h` cell buffers, both cleared to blank glyph /
        # default fg.
        def resize(w : Int32, h : Int32)
          reset_slots w, h
          @cell_glyph = Array(Char).new(w * h, ' ')
          @cell_color = Array(Int32).new(w * h, -1)
        end

        # Resolves one frame of the spray simulation into the flat cell buffers,
        # then advances time. Sets `@done` once a non-looping spray has finished
        # filling.
        def advance(w : Int32, h : Int32)
          return @done = false if w <= 0 || h <= 0 || @slots.empty?
          recompute w, h
          @frame += 1
          @done = !repeat? && @frame > fill_frame
        end

        # Projects every slot to its position/glyph/color for the current frame and
        # writes it into the flat cell buffers, cleared first so uncovered cells
        # fall back to blank. Allocation-free: only overwrites the buffers
        # `#resize` sized.
        private def recompute(w, h)
          ox, oy = emitter(w, h)
          # `spacing`/`travel`/`hold` are all plain knobs an app may zero out
          # ("fill instantly, loop immediately"), making the cycle 0 — and
          # `@frame % 0` would raise `DivisionByZeroError` and kill the
          # animation fiber. Floor at 1: `f` is then 0 every frame and the
          # degenerate configuration renders the fully-landed pattern instead.
          # (Also covers a negative `hold` driving the cycle below zero, which
          # would otherwise freeze the spray in the pending-spark state.)
          cycle = Math.max(1, fill_frame + @hold)
          f = repeat? ? @frame % cycle : @frame

          @cell_glyph.fill(' ')
          @cell_color.fill(-1)

          @slots.each_with_index do |(dx, dy, ch), i|
            launch = i * @spacing
            if f < launch
              # Slots are ordered by increasing `launch`, so once one is pending
              # every later slot is too, and all resolve to the same emitter
              # cell/glyph. The last one written (`@slots.size - 1`) is what
              # survives, so write it once and stop.
              if 0 <= ox < w && 0 <= oy < h
                idx = oy * w + ox
                @cell_glyph[idx] = '·'
                @cell_color[idx] = colorize @slots.size - 1, Phase::Pending
              end
              break
            elsif f < launch + @travel
              p = (f - launch) / @travel.to_f
              gx = (ox + (dx - ox) * p).round.to_i
              gy = (oy + (dy - oy) * p).round.to_i
              gch = @grow[(p * @grow.size).to_i.clamp(0, @grow.size - 1)][0]
              phase = Phase::Flight
            else
              gx, gy, gch, phase = dx, dy, ch, Phase::Landed
            end
            next unless 0 <= gx < w && 0 <= gy < h
            idx = gy * w + gx
            @cell_glyph[idx] = gch
            @cell_color[idx] = colorize i, phase
          end
        end

        # Glyph and packed `0xRRGGBB` fg (or `-1` for widget default) for interior
        # cell `{x, y}`, read from the buffers `#advance` filled.
        def cell(x : Int32, y : Int32, w : Int32, h : Int32) : {Char, Int32}
          idx = y * w + x
          {@cell_glyph[idx], @cell_color[idx]}
        end

        # Color (native `0xRRGGBB`) for slot *i* in *phase* at the current frame.
        private def colorize(i : Int32, phase : Phase) : Int32
          if c = @color
            # The public color proc's frame param is `Int32`; wrap rather than
            # raise if the Int64 counter exceeds it.
            return c.call(i, @frame.to_i32!, phase)
          end
          case phase
          in .pending? then @spark_colors[(@frame // 3) % @spark_colors.size]
          in .flight?  then Colors::HSV_LUT[((@frame * 9 + i * 9) % 360).to_i32]
          in .landed?  then Colors::HSV_LUT[((@frame * 6 + i * 9) % 360).to_i32]
          end
        end

        # A non-looping spray finishes once it has filled the area, at which point
        # the animation loop stops and runs `#on_complete`.
        protected def done? : Bool
          @done
        end

        protected def on_done
          @on_complete.try &.call
        end

        # Restart the spray from an empty area on the next frame.
        def restart
          @frame = 0_i64
          @done = false
        end
      end
    end
  end
end
