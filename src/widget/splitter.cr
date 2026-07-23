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
    # sp.add_widget Widget::Box.new(content: "a")
    # sp.add_widget Widget::Box.new(content: "b")
    # sp.add_widget Widget::Box.new(content: "c")
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![Splitter screenshot](../../tests/widget/splitter/splitter.5s.apng)
    # <!-- /widget-examples:capture -->
    class Splitter < Box
      getter orientation : Tput::Orientation = :horizontal

      # Changing orientation at runtime re-lays the panes out along the new
      # axis and repaints (Qt's `QSplitter#setOrientation`). `#place_pane`
      # clears the sizes the old axis pinned, so panes stretch across the new
      # cross axis instead of keeping their old extents.
      def orientation=(v : Tput::Orientation) : Tput::Orientation
        return v if v == @orientation
        @orientation = v
        relayout
        request_render
        v
      end

      # The panes, in order.
      getter panes = [] of Widget

      @dividers = [] of Box

      # The dividers (one fewer than `#panes`), in order. A copy: these boxes are
      # the splitter's own machinery, and adding or dropping one here would leave
      # them out of step with the pane list. Move one with
      # `#set_divider_position`; add panes with `#add_widget`.
      def dividers : Array(Box)
        @dividers.dup
      end

      # Divider offsets along the split axis, in content cells (sorted
      # ascending); `#positions[i]` separates pane `i` from pane `i+1`.
      @positions = [] of Int32

      # Whether the user has set a divider explicitly (drag, keys, or an explicit
      # `set_divider_position`). Until then, panes re-even to the current span on every
      # layout, so a splitter sized by a layout engine settles at its final size
      # rather than an early, wrong distribution. Once adjusted, only clamps.
      @user_positioned = false

      def initialize(@orientation = @orientation, **box)
        super **box

        on(Crysterm::Event::Attached) { relayout }
        on(Crysterm::Event::Resize) { relayout; request_render }
      end

      # Relayout on every paint: pane sizes depend on the splitter's resolved
      # span, only known once coordinates are computed. The `Resize`/`Attached`
      # hooks cover the headless/no-render paths.
      def render(with_children = true)
        relayout
        refresh_divider_glyphs
        super
      end

      # An unstyled divider is an invisible one-cell gap, so fill it with the
      # orientation-appropriate line glyph (`│`/`─`); under a theme it's a
      # colored bar instead and the glyph is cleared.
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

      # Appends a pane to the right/bottom, inserting a draggable divider before
      # it (except for the first pane). Existing dividers are re-evened.
      def add_widget(widget : Widget) : self
        unless @panes.empty?
          @dividers << make_divider(@dividers.size)
          @positions << 0
        end

        @panes << widget
        append widget
        @dividers.each &.to_front

        even_positions
        relayout
        self
      end

      # Operator alias for `#add_widget`, e.g. `splitter << pane`. Deliberately
      # overrides the inherited `Mixin::Children#<<` (which only appends a raw
      # child): a `Splitter`'s children are panes, so every append must also
      # register the pane and its divider. `#add_widget` calls `append` itself, so
      # child bookkeeping is preserved.
      def <<(widget : Widget) : self
        add_widget widget
      end

      # Number of panes (Qt's `QSplitter#count`).
      def count : Int32
        @panes.size
      end

      # The pane at *index*, or `nil` when out of range (Qt's `QSplitter#widget`).
      def widget(index : Int) : Widget?
        @panes[index]?
      end

      # Index of *widget* among the panes, or `nil` when it is not one. Qt's
      # `QSplitter#indexOf` returns `-1`; this returns the idiomatic `nil`.
      def index_of(widget : Widget) : Int32?
        @panes.index widget
      end

      # Inserts *widget* as a pane at *index* (clamped to the end), like Qt's
      # `QSplitter#insertWidget`. Appending is the common case and keeps the
      # existing dividers untouched; a mid-list insert renumbers the dividers, so
      # they are rebuilt and the panes re-evened.
      def insert_widget(index : Int, widget : Widget) : self
        i = index.clamp(0, @panes.size)
        return add_widget widget if i >= @panes.size
        @panes.insert i, widget
        append widget
        rebuild_dividers
        self
      end

      # Removes *widget* from the panes, detaching (not destroying) it, and
      # returns it — or `nil` when it is not a pane. The dividers are rebuilt
      # and the remaining panes re-evened; the actual bookkeeping lives in the
      # `#remove` override so every detach path shares it.
      def remove_widget(widget : Widget) : Widget?
        return unless @panes.includes? widget
        remove widget
        widget
      end

      # Counterpart of the `#<<` override: every detach must also unregister
      # the pane and rebuild the dividers, whatever the path — `#remove_widget`,
      # a generic `#remove`, `Widget#destroy` or `#detach_from_tree` (both of
      # which land here via `parent.remove(self)`), or a reparenting append.
      # Dividers themselves pass through untouched (`rebuild_dividers` removes
      # them with this very method).
      def remove(element)
        was_pane = @panes.includes? element
        super
        if was_pane
          @panes.delete element
          rebuild_dividers
        end
      end

      # Recreates the divider boxes (one fewer than `#panes`) after a mid-list
      # insert renumbers them: each divider's drag/key handlers capture their
      # positional index, so keeping the old boxes would drive the wrong split.
      # Positions are re-evened across the new arrangement.
      private def rebuild_dividers : Nil
        @dividers.each { |d| remove d }
        @dividers.clear
        @positions.clear
        @user_positioned = false
        (@panes.size - 1).times do |idx|
          @dividers << make_divider(idx)
          @positions << 0
        end
        @dividers.each &.to_front
        even_positions
        relayout
      end

      # --- Pane sizes (Qt's `QSplitter#sizes`) ---------------------------------

      # Extent of each pane along the split axis, in content cells — one entry per
      # pane, the dividers' own cells excluded.
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

      # Builds a divider box wired to split index *idx*: a one-cell,
      # draggable/keyboard-movable `Box` carrying the `.divider` css class
      # (themed via `.divider { ... }`). The single construction site for both
      # `#add_widget` and `#rebuild_dividers`; callers push the matching
      # `@positions << 0` themselves to keep the divider/position counts in step.
      private def make_divider(idx : Int) : Box
        div = Box.new(
          parent: self,
          draggable: true,
          keys: true,
          top: 0, left: 0, width: 1, height: 1,
        )
        div.add_css_class "divider"
        wire_divider div, idx
        div
      end

      private def wire_divider(div : Box, i : Int)
        # Drive the split from the pointer position relative to the splitter's
        # content origin, not the built-in `draggable` reposition, which moves
        # `left`/`top` in parent-relative terms — only correct at the window
        # origin.
        div.on(Crysterm::Event::Drag) do |e|
          # `e.x`/`e.y` are painted coords; resolve against the splitter's
          # painted origin (with a pre-render layout fallback), so a drag inside
          # a scrolled container isn't offset by the enclosing scroll base.
          origin_x, origin_y = painted_origin
          if horizontal?
            set_divider_position i, e.x - origin_x - ileft
          else
            set_divider_position i, e.y - origin_y - itop
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
      #   pulls every divider back inside it.
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
        # Fill `@positions` in place: this runs every frame while
        # `@user_positioned` is false, so a freshly mapped array would be
        # per-frame garbage. Rebuild only on the rare size mismatch.
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
          # Clear any size a previous vertical layout pinned; an explicit Int32
          # `height` would otherwise win over the `top: 0`/`bottom: 0` stretch.
          pane.height = nil
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
          # Symmetric: clear the width a previous horizontal layout pinned.
          pane.width = nil
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
          div.right = nil # clear the anchor a previous vertical layout set
          div.width = 1
          div.height = nil
        else
          div.left = 0
          div.right = 0
          div.top = pos
          div.bottom = nil # clear the anchor a previous horizontal layout set
          div.height = 1
          div.width = nil
        end
      end
    end
  end
end
