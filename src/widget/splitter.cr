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
    # sp = Widget::Splitter.new parent: screen, width: 60, height: 20
    # sp.add_pane Widget::Box.new(content: "a")
    # sp.add_pane Widget::Box.new(content: "b")
    # sp.add_pane Widget::Box.new(content: "c")
    # ```
    #
    # The original two-pane API (`#split`, `#pane1`/`#pane2`, `#divider`,
    # `#position`) is retained as a convenience over the general one.
    class Splitter < Box
      property orientation : Tput::Orientation = :horizontal

      # The panes, in order.
      getter panes = [] of Widget
      # The dividers (one fewer than `#panes`).
      getter dividers = [] of Box

      # Divider offsets along the split axis, in content cells (sorted
      # ascending); `#positions[i]` separates pane `i` from pane `i+1`.
      @positions = [] of Int32
      @init_position : Int32?

      def initialize(@orientation = @orientation, position = nil, **box)
        @init_position = position

        super **box

        on(Crysterm::Event::Attach) { relayout }
        on(Crysterm::Event::Resize) { relayout; request_render }
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
            style: Style.new(bg: "white"),
          )
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

      # The first divider (raises if there isn't one yet).
      def divider : Box
        @dividers.first
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

      # --- General divider control ---------------------------------------------

      def divider_position(i : Int) : Int32
        @positions[i]? || 0
      end

      # Sets divider *i*'s offset (clamped so neither neighbor pane collapses
      # below one cell) and re-lays out.
      def set_divider_position(i : Int, pos : Int) : Nil
        return unless 0 <= i < @positions.size
        @positions[i] = clamp_position(i, pos.to_i)
        relayout
        request_render
      end

      # Re-derives the first divider's position from where it currently sits
      # (compatibility shim used by older callers).
      def sync_from_divider : Nil
        div = @dividers[0]?
        return unless div
        if horizontal?
          set_divider_position 0, (div.left.as?(Int32) || @positions[0]? || 0)
        else
          set_divider_position 0, (div.top.as?(Int32) || @positions[0]? || 0)
        end
      end

      # --- Internals -----------------------------------------------------------

      private def wire_divider(div : Box, i : Int)
        # Drive the split from the *pointer's* position relative to the splitter's
        # content origin. The built-in `draggable` reposition also fires and moves
        # the divider's `left`/`top`, but those are parent-relative while the
        # pointer is absolute — only correct when the splitter sits at the screen
        # origin. Using the event coordinates works wherever the splitter is, and
        # `set_divider_position` → `relayout` snaps the divider back onto its track.
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
        span = horizontal? ? (awidth - iwidth) : (aheight - iheight)
        if span <= 0
          configured = (horizontal? ? @width : @height).as?(Int32) || 0
          span = configured - (horizontal? ? iwidth : iheight)
        end
        Math.max(0, span)
      end

      # Clamps divider *i*'s position so each side keeps at least one cell, given
      # its neighbors.
      private def clamp_position(i : Int, pos : Int32) : Int32
        total = total_span
        return pos if total <= 0
        min = i == 0 ? 1 : @positions[i - 1] + 2
        max = i == @positions.size - 1 ? total - 2 : @positions[i + 1] - 2
        max = min if max < min
        pos.clamp(min, max)
      end

      # Distributes the dividers evenly across the available span.
      private def even_positions
        n = @panes.size
        return if n < 2
        total = total_span
        return if total <= 0
        w = Math.max(1, (total - (n - 1)) // n)
        @positions = (0...n - 1).map { |i| (i + 1) * w + i }
        @positions.each_index { |i| @positions[i] = clamp_position(i, @positions[i]) }
      end

      private def relayout
        return if @panes.empty?
        total = total_span
        return if total <= 0
        n = @panes.size

        even_positions if @positions.size != n - 1
        @positions.each_index { |i| @positions[i] = clamp_position(i, @positions[i]) }

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
      # edge (so it always meets the container border) rather than carrying an
      # explicit size.
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
