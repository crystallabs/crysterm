require "./box"

module Crysterm
  class Widget
    # Multi-pane container with draggable dividers, modeled after Qt's
    # `QSplitter`.
    #
    # Holds any number of child panes laid out side by side (`:horizontal`) or
    # stacked (`:vertical`), separated by one-cell dividers. Dragging a divider
    # with the mouse — or moving it with the arrow keys when focused — resizes the
    # two panes around it; divider offsets can also be set programmatically.
    #
    # ```
    # sp = Widget::Splitter.new parent: window, width: 60, height: 20
    # sp.add_pane Widget::Box.new(content: "a")
    # sp.add_pane Widget::Box.new(content: "b")
    # sp.add_pane Widget::Box.new(content: "c")
    # ```
    #
    # The original two-pane API (`#split`, `#pane1`/`#pane2`, `#divider`,
    # `#position`) is retained as a convenience over the general one.
    #
    # <!-- widget-examples:capture v1 -->
    # ![Splitter screenshot](../../tests/widget/splitter/splitter.5s.apng)
    # <!-- /widget-examples:capture -->
    class Splitter < Box
      property orientation : Tput::Orientation = :horizontal

      # The panes, in order.
      getter panes = [] of Widget

      @dividers = [] of Box

      # The dividers (one fewer than `#panes`), in order. A copy: these boxes are
      # the splitter's own machinery, placed by `#relayout` from `#positions` —
      # adding or dropping one here would leave the two out of step. Move one with
      # `#set_divider_position`; add panes with `#add_pane`.
      def dividers : Array(Box)
        @dividers.dup
      end

      # Divider offsets along the split axis, in content cells (sorted
      # ascending); `#positions[i]` separates pane `i` from pane `i+1`.
      @positions = [] of Int32
      @init_position : Int32?

      # Whether the user has set a divider explicitly (drag, keys, or an explicit
      # `position`). Until then, panes re-even to the current span on every
      # layout, so a splitter sized by a layout engine settles at its final size
      # rather than an early, wrong distribution. Once adjusted, only clamps.
      @user_positioned = false

      def initialize(@orientation = @orientation, position = nil, **box)
        @init_position = position

        super **box

        on(Crysterm::Event::Attach) { relayout }
        on(Crysterm::Event::Resize) { relayout; request_render }
      end

      # Relayout on every paint. Pane sizes depend on the splitter's resolved
      # span, only known once coordinates are computed. Doing layout here (as
      # well as in the `Resize`/`Attach` hooks, which cover headless/no-render
      # paths) guarantees panes are fitted to the span actually being painted.
      def render(with_children = true)
        relayout
        refresh_divider_glyphs
        super
      end

      # An unstyled divider (no `.divider { background: … }` theme rule, i.e.
      # not `css_styled`) is otherwise an invisible one-cell gap. Fill it with
      # the orientation-appropriate line glyph (`│`/`─`) so the split reads on
      # any terminal; under a theme it's a colored bar instead, so the glyph is
      # cleared. Written through `state_style` so it persists like any other
      # programmatic default.
      private def refresh_divider_glyphs
        line_glyph = glyph(horizontal? ? Glyphs::Role::LineVertical : Glyphs::Role::LineHorizontal)
        @dividers.each do |div|
          ch = div.css_styled? ? ' ' : line_glyph
          st = div.state_style
          st.fill_char = ch unless st.fill_char == ch
        end
      end

      def horizontal? : Bool
        @orientation.horizontal?
      end

      # Two-pane convenience: assigns both panes (and the single divider) at once.
      def split(first : Widget, second : Widget) : self
        add_pane first
        add_pane second
        if p = @init_position
          set_divider_position 0, p if p > 0
        end
        self
      end

      # Appends a pane to the right/bottom, inserting a draggable divider before
      # it (except for the first pane). Existing dividers are re-evened.
      def add_pane(widget : Widget) : self
        unless @panes.empty?
          idx = @dividers.size
          div = Box.new(
            parent: self,
            draggable: true,
            keys: true,
            top: 0, left: 0, width: 1, height: 1,
          )
          div.add_css_class "divider" # themed via `.divider { ... }`
          wire_divider div, idx
          @dividers << div
          @positions << 0
        end

        @panes << widget
        append widget
        @dividers.each &.front!

        even_positions
        relayout
        self
      end

      # --- Two-pane compatibility accessors ------------------------------------

      def pane1 : Widget?
        @panes[0]?
      end

      def pane2 : Widget?
        @panes[1]?
      end

      # The first divider, or `nil` when there are fewer than two panes — mirroring
      # `#pane1`/`#pane2`, which are `Widget?` for exactly the same reason. (It
      # used to raise on an empty splitter while its two siblings answered `nil`.)
      def divider : Box?
        @dividers.first?
      end

      # Offset of the first divider.
      def position : Int32
        @positions[0]? || 0
      end

      # Sets the first divider's offset.
      def position=(value : Int32) : Int32
        set_divider_position 0, value
        value
      end

      # --- Pane sizes (Qt's `QSplitter#sizes`) ---------------------------------

      # Extent of each pane along the split axis, in content cells — one entry per
      # pane, the dividers' own cells excluded. The pane-side view of the divider
      # offsets `#divider_position` reports.
      def sizes : Array(Int32)
        n = @panes.size
        return [] of Int32 if n == 0
        total = total_span
        Array(Int32).new(n) do |i|
          start = i == 0 ? 0 : @positions[i - 1] + 1
          stop = i == n - 1 ? total : @positions[i]
          Math.max(1, stop - start)
        end
      end

      # Resizes the panes to *values* (Qt's `setSizes`): the divider offsets are
      # the running sum of the wanted extents (plus one cell for each divider
      # passed), then clamped so no pane collapses. Extra entries are ignored;
      # missing ones leave that pane at its current extent. Like a drag, this
      # counts as positioning the splitter by hand, so it stops re-evening its
      # panes on every layout.
      def sizes=(values : Enumerable(Int32)) : Nil
        return if @panes.size < 2
        want = values.to_a
        # Snapshot before mutating: the fallback for a missing entry is the
        # pane's extent *now*.
        cur = sizes
        @user_positioned = true
        pos = 0
        @positions.each_index do |i|
          pos += (want[i]? || cur[i]? || 1)
          @positions[i] = pos
          pos += 1 # the divider's own cell
        end
        # Left-to-right, so each clamp sees the already-settled divider behind it.
        @positions.each_index { |i| @positions[i] = clamp_position(i, @positions[i]) }
        relayout
        request_render
      end

      # --- General divider control ---------------------------------------------

      def divider_position(i : Int) : Int32
        @positions[i]? || 0
      end

      # Sets divider *i*'s offset (clamped so neither neighbor pane collapses
      # below one cell) and re-lays out.
      def set_divider_position(i : Int, pos : Int) : Nil
        return unless 0 <= i < @positions.size
        @user_positioned = true
        @positions[i] = clamp_position(i, pos.to_i)
        relayout
        request_render
      end

      # --- Internals -----------------------------------------------------------

      private def wire_divider(div : Box, i : Int)
        # Drive the split from the pointer position relative to the splitter's
        # content origin, not the built-in `draggable` reposition (which moves
        # `left`/`top` in parent-relative terms, only correct at the window
        # origin). `set_divider_position` → `relayout` snaps the divider back
        # onto its track.
        div.on(Crysterm::Event::Drag) do |e|
          if horizontal?
            set_divider_position i, e.x - aleft - ileft
          else
            set_divider_position i, e.y - atop - itop
          end
        end

        div.on(Crysterm::Event::KeyPress) do |e|
          dec = horizontal? ? Tput::Key::Left : Tput::Key::Up
          inc = horizontal? ? Tput::Key::Right : Tput::Key::Down
          if e.key == dec
            set_divider_position i, divider_position(i) - 1
            e.accept
          elsif e.key == inc
            set_divider_position i, divider_position(i) + 1
            e.accept
          end
        end
      end

      # Span (in content cells) along the split axis, falling back to the
      # configured size minus insets when not laid out yet.
      private def total_span : Int32
        span = horizontal? ? (awidth - ihorizontal) : (aheight - ivertical)
        if span <= 0
          configured = (horizontal? ? @width : @height).as?(Int32) || 0
          span = configured - (horizontal? ? ihorizontal : ivertical)
        end
        Math.max(0, span)
      end

      # Clamps divider *i*'s position so the layout stays valid regardless of
      # its neighbors. Two constraints:
      #
      # * *Absolute room* — panes/dividers on either side need at least one
      #   cell each, so *i* can't go below `1 + 2*i` nor above
      #   `total - 2*(n-1-i)`. Depends only on `total`, so a shrinking span
      #   pulls every divider back inside it (clamping solely against neighbor
      #   offsets let a divider stay past the right edge after a resize).
      # * *Non-crossing* — tightened against live neighbor offsets so a dragged
      #   divider can't pass the one beside it.
      private def clamp_position(i : Int, pos : Int32) : Int32
        total = total_span
        return pos if total <= 0
        n = @panes.size
        lo = 1 + 2*i
        hi = total - 2*(n - 1 - i)
        lo = Math.max(lo, @positions[i - 1] + 2) if i > 0
        hi = Math.min(hi, @positions[i + 1] - 2) if i < @positions.size - 1
        hi = lo if hi < lo
        pos.clamp(lo, hi)
      end

      # Distributes the dividers evenly across the available span.
      private def even_positions
        n = @panes.size
        return if n < 2
        total = total_span
        return if total <= 0
        w = Math.max(1, (total - (n - 1)) // n)
        # Fill `@positions` in place (it is already sized `n-1` by `add_pane`)
        # rather than reassigning a freshly `.map`-ped array — this runs from
        # `#render`'s `relayout` every frame while `@user_positioned` is false, so
        # the per-frame array allocation was pure garbage. Rebuild only on the
        # rare size mismatch.
        if @positions.size == n - 1
          (0...n - 1).each { |i| @positions[i] = (i + 1) * w + i }
        else
          @positions.clear
          (0...n - 1).each { |i| @positions << (i + 1) * w + i }
        end
        @positions.each_index { |i| @positions[i] = clamp_position(i, @positions[i]) }
      end

      private def relayout
        return if @panes.empty?
        total = total_span
        return if total <= 0
        n = @panes.size

        # Until the user pins a divider, keep panes evenly fitted to the current
        # span (so a layout-driven resize always re-fits); afterwards just clamp
        # the user's positions into the available space.
        if @user_positioned && @positions.size == n - 1
          @positions.each_index { |i| @positions[i] = clamp_position(i, @positions[i]) }
        else
          even_positions
        end

        @panes.each_with_index do |pane, i|
          start = i == 0 ? 0 : @positions[i - 1] + 1
          stop = i == n - 1 ? total : @positions[i]
          place_pane pane, start, Math.max(1, stop - start), last: i == n - 1
        end

        @dividers.each_with_index do |div, i|
          place_divider div, @positions[i]
        end
      end

      # Lays out a pane between two boundaries. The final pane fills to the far
      # edge (meeting the container border) rather than carrying an explicit size.
      private def place_pane(pane : Widget, start : Int32, size : Int32, last : Bool)
        if horizontal?
          pane.top = 0
          pane.bottom = 0
          pane.left = start
          if last
            pane.right = 0
            pane.width = nil
          else
            pane.right = nil
            pane.width = size
          end
        else
          pane.left = 0
          pane.right = 0
          pane.top = start
          if last
            pane.bottom = 0
            pane.height = nil
          else
            pane.bottom = nil
            pane.height = size
          end
        end
      end

      private def place_divider(div : Box, pos : Int32)
        if horizontal?
          div.top = 0
          div.bottom = 0
          div.left = pos
          div.width = 1
          div.height = nil
        else
          div.left = 0
          div.right = 0
          div.top = pos
          div.height = 1
          div.width = nil
        end
      end
    end
  end
end
