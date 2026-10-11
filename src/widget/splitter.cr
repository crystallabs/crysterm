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
    # A hidden pane takes no room and shows no divider, as a `QSplitter` folds
    # a hidden widget away; shown again, it gets back the extent it had. The
    # panes grow and shrink with the splitter in proportion to their extents
    # (`#set_stretch_factor` exempts some, for a fixed column), and
    # `#save_state`/`#restore_state` carry the layout across runs.
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
        update!
        v
      end

      # The panes, in order.
      getter panes = [] of Widget

      @dividers = [] of Divider

      # One divider of a `Splitter`: the draggable one-cell `Box` between two
      # panes, and the item object through which its offset is read and moved:
      #
      # ```
      # splitter.dividers[0].position = 20
      # ```
      #
      # Excluded from the DOM-loader registry: a divider only exists as part of
      # its `Splitter` (see `Crysterm::DOM::Skip`).
      @[::Crysterm::DOM::Skip]
      class Divider < Box
        # The splitter this divider belongs to, and which split it marks
        # (`#index` `i` separates pane `i` from the next shown pane; the
        # divider is hidden while pane `i` is, or while no shown pane follows).
        getter index : Int32

        def initialize(@owner : Splitter, @index : Int32, **box)
          super **box
        end

        # This divider's offset along the split axis, in content cells.
        def position : Int32
          @owner.position_of @index
        end

        # Moves this divider, clamped so neither neighbor pane collapses below
        # one cell, and re-lays the splitter out.
        def position=(pos : Int) : Int32
          @owner.move_divider @index, pos
          position
        end
      end

      # The dividers (one fewer than `#panes`), in order. A copy of the array:
      # these boxes are the splitter's own machinery, and adding or dropping one
      # here would leave them out of step with the pane list. Move one with
      # `dividers[i].position =`; add panes with `#add_widget`.
      def dividers : Array(Divider)
        @dividers.dup
      end

      # Divider offsets along the split axis, in content cells (sorted
      # ascending), as the last layout placed them; `#positions[i]` separates
      # pane `i` from the next shown pane. Derived from the panes' extents on
      # every layout, not the other way round: what the panes want (`@wanted`)
      # is the state, as in Qt.
      @positions = [] of Int32

      # The extent each pane wants along the split axis, in content cells —
      # Qt's per-pane `sizer`: what `#sizes=` asked for, or the extents as
      # they stood after the last drag or key move (`#store_sizes`), so later
      # layouts keep the proportions the user settled on. `0` is a pane never
      # sized: it takes an even share, so a fresh splitter splits evenly and
      # re-fits to its span on every layout until a divider is moved. A
      # hidden pane keeps its entry, and gets the extent back when shown.
      @wanted = [] of Int32

      # Stretch factors (Qt's `QSplitter#setStretchFactor`), one per pane.
      # With none set, every pane grows and shrinks with the splitter in
      # proportion to its extent. With some set, only the panes with a factor
      # do; the others keep the extent they want, a fixed column beside
      # stretching ones.
      @stretch = [] of Int32

      # The extent each pane got from the last layout (0 while hidden); what
      # `#sizes` reports. Filled in place every frame, like `@positions`.
      @fitted = [] of Int32

      # Set for the duration of `#destroy`: guards `#rebuild_dividers` against
      # allocating fresh `Divider`s while the panes are being torn down one by
      # one underneath it.
      @destroying = false

      def initialize(@orientation = @orientation, **box)
        super **box

        on(Crysterm::Event::Attached) { relayout }
        on(Crysterm::Event::Resize) { relayout; update! }
      end

      # Tears the splitter and every pane/divider down. Dividers aren't
      # rebuilt mid-teardown — see `#rebuild_dividers`.
      def destroy
        @destroying = true
        super
      end

      # Relayout on every paint: pane sizes depend on the splitter's resolved
      # span, only known once coordinates are computed. The `Resize`/`Attached`
      # hooks cover the headless/no-render paths.
      def paint(*, with_children = true)
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
      # it (except for the first pane). The new pane wants no extent yet, so it
      # takes an even share of the span.
      #
      # Re-adding a pane the splitter already holds is a move: it is dropped
      # from its current slot first (rebuilding the divider set for the
      # shrunk pane list) so the fresh divider pushed below and the append
      # land on a consistent count, rather than appending a duplicate that
      # `#remove` would later delete out from under the pane list.
      def add_widget(widget : Widget) : self
        remove_widget widget

        unless @panes.empty?
          @dividers << make_divider(@dividers.size)
          @positions << 0
        end

        # Append before registering the pane: if this attach still has to
        # detach the widget from elsewhere, that detach's own bookkeeping
        # (including a same-splitter `#remove`) runs against a `@panes` that
        # doesn't yet list it.
        append widget
        @panes << widget
        @wanted << 0
        @stretch << 0
        @fitted << 0
        @dividers.each &.to_front

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
      # they are rebuilt.
      #
      # Re-inserting a pane the splitter already holds is a move: dropped from
      # its current slot first (see `#add_widget`), with *index* then clamped
      # against the post-removal pane count.
      def insert_widget(index : Int, widget : Widget) : self
        remove_widget widget

        i = index.clamp(0, @panes.size)
        return add_widget widget if i >= @panes.size
        append widget
        @panes.insert i, widget
        @wanted.insert i, 0
        @stretch.insert i, 0
        @fitted.insert i, 0
        rebuild_dividers
        self
      end

      # Removes *widget* from the panes, detaching (not destroying) it, and
      # returns it — or `nil` when it is not a pane. The dividers are rebuilt
      # and the remaining panes re-fitted; the actual bookkeeping lives in the
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
      #
      # Deletes by the captured index, not by value: `element` may sit at only
      # one slot (a duplicate pane is deduped in `#add_widget`/`#insert_widget`
      # before it could ever reach `@panes` twice), and index-based removal
      # keeps it that way rather than dropping every `==`-equal entry.
      def remove(element)
        idx = @panes.index element
        super
        if idx
          @panes.delete_at idx
          @wanted.delete_at idx
          @stretch.delete_at idx
          @fitted.delete_at idx
          rebuild_dividers
        end
      end

      # Recreates the divider boxes (one fewer than `#panes`) after a mid-list
      # insert renumbers them: each divider's drag/key handlers capture their
      # positional index, so keeping the old boxes would drive the wrong split.
      # The panes keep the extents they want; the dividers are placed from
      # them afresh.
      #
      # A no-op while the splitter itself is being torn down (`#destroy`):
      # each pane's own teardown detaches through `#remove`, and rebuilding
      # after every single one would allocate fresh `Divider`s on a splitter
      # that's on its way out anyway.
      private def rebuild_dividers : Nil
        return if @destroying

        @dividers.each { |d| remove d }
        @dividers.clear
        @positions.clear
        (@panes.size - 1).times do |idx|
          @dividers << make_divider(idx)
          @positions << 0
        end
        @dividers.each &.to_front
        relayout
      end

      # --- Pane sizes (Qt's `QSplitter#sizes`) ---------------------------------

      # Extent of each pane along the split axis, in content cells, as laid
      # out now — one entry per pane, the dividers' own cells excluded, `0`
      # for a hidden pane (as Qt's `sizes` answers). Laid out on the spot, so
      # the answer is current between frames.
      def sizes : Array(Int32)
        relayout
        @fitted.dup
      end

      # Resizes the panes to *values* (Qt's `setSizes`): each becomes the
      # extent its pane wants, and the layout fits them to the span — exactly
      # when they add up to it, in proportion otherwise (`#fit`) — with no
      # pane below one cell. A value of 0 or less asks for nothing in
      # particular: an even share (Qt collapses such a pane; here panes do not
      # collapse). Extra entries are ignored; the panes missing one share what
      # the given extents leave of the span, in proportion to their extents
      # now, so a short vector resizes the panes it names and the last pane
      # takes up the slack. Hidden panes take their values too, for when they
      # are shown.
      def sizes=(values : Enumerable(Int32)) : Nil
        return if @panes.empty?
        want = values.to_a
        relayout
        left = available_span
        rest = 0
        @panes.each_index do |i|
          if v = want[i]?
            @wanted[i] = Math.max(0, v)
            left -= @wanted[i] if shown?(i)
          elsif shown?(i)
            rest += @fitted[i]
          end
        end
        if rest > 0
          @panes.each_index do |i|
            next if want[i]? || !shown?(i)
            @wanted[i] = Math.max(1, left * @fitted[i] // rest)
          end
        end
        relayout
        update!
      end

      # The extents the panes want, hidden ones included — what to keep across
      # runs and hand to `#restore_state` next time (Qt's `saveState`, which
      # also carries the orientation and handle width; here those are the
      # caller's construction). A pane never sized has 0: no wish recorded.
      def save_state : Array(Int32)
        @wanted.dup
      end

      # Brings back a layout `#save_state` returned (Qt's `restoreState`):
      # `#sizes=` with *state*, which the layout fits to the span as it is
      # now, so a splitter wider or narrower than the one saved keeps the
      # proportions. Returns false, and changes nothing, for a *state* that is
      # not one entry per pane (another pane count, or data from elsewhere).
      def restore_state(state : Enumerable(Int32)) : Bool
        list = state.to_a
        return false if list.empty? || list.size != @panes.size
        self.sizes = list
        true
      end

      # The stretch factor of pane *index*: 0 unless `#set_stretch_factor`
      # gave it one.
      def stretch_factor(index : Int) : Int32
        @stretch[index]? || 0
      end

      # Gives pane *index* stretch factor *stretch* (Qt's `setStretchFactor`).
      # Once any pane has one, the panes with a factor absorb the splitter's
      # growth and shrinkage between them, in proportion to their extents, and
      # the panes without keep the extent they want: the way to a fixed-width
      # side column beside stretching main panes. The factor's size does not
      # weigh, as in Qt; non-zero is what counts.
      def set_stretch_factor(index : Int, stretch : Int) : Nil
        return unless 0 <= index < @panes.size
        @stretch[index] = stretch.to_i
        relayout
        update!
      end

      # --- General divider control ---------------------------------------------

      # Divider *i*'s offset along the split axis. Reached through
      # `Divider#position`, which is the public spelling.
      protected def position_of(i : Int) : Int32
        @positions[i]? || 0
      end

      # Sets divider *i*'s offset and re-lays out: the panes on either side —
      # pane *i* and the next shown one — trade cells, clamped so neither goes
      # below one, and every shown pane's extent becomes what it wants
      # (`#store_sizes`), so proportions set by hand outlive the next resize.
      # Nothing moves for a hidden divider. Reached through `Divider#position=`.
      protected def move_divider(i : Int, pos : Int) : Nil
        return unless 0 <= i < @positions.size
        relayout
        a = i.to_i
        return unless shown?(a) && (b = next_shown(a))
        start = @positions[a] - @fitted[a]
        stop = @positions[a] + 1 + @fitted[b]
        pos = pos.to_i.clamp(start + 1, Math.max(start + 1, stop - 2))
        @fitted[a] = pos - start
        @fitted[b] = stop - pos - 1
        store_sizes
        relayout
        update!
      end

      # --- Internals -----------------------------------------------------------

      # Builds a divider box wired to split index *idx*: a one-cell,
      # draggable/keyboard-movable `Box` carrying the `.divider` css class
      # (themed via `.divider { ... }`). The single construction site for both
      # `#add_widget` and `#rebuild_dividers`; callers push the matching
      # `@positions << 0` themselves to keep the divider/position counts in step.
      private def make_divider(idx : Int) : Divider
        div = Divider.new(
          self, idx.to_i,
          parent: self,
          draggable: true,
          keys: true,
          top: 0, left: 0, width: 1, height: 1,
        )
        div.add_css_class "divider"
        # Off the Tab chain (Qt's handles take no focus at all): Tab cycles
        # the panes, and a divider is reached by clicking it or by the
        # application focusing it (`Divider#focus`), after which the arrow
        # keys move it.
        div.focus_policy = :click
        wire_divider div, idx
        div
      end

      private def wire_divider(div : Divider, i : Int)
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
            move_divider i, e.x - origin_x - ileft
          else
            move_divider i, e.y - origin_y - itop
          end
        end

        div.on(Crysterm::Event::KeyPress) do |e|
          dec = horizontal? ? Tput::Key::Left : Tput::Key::Up
          inc = horizontal? ? Tput::Key::Right : Tput::Key::Down
          if e.key == dec
            move_divider i, position_of(i) - 1
            e.accept
          elsif e.key == inc
            move_divider i, position_of(i) + 1
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

      # The span left to the shown panes once their dividers took a cell each.
      private def available_span : Int32
        total_span - Math.max(0, shown_count - 1)
      end

      private def shown_count : Int32
        @panes.count { |pane| !pane.hidden? }
      end

      private def shown?(i : Int32) : Bool
        !@panes[i].hidden?
      end

      # The index of the first shown pane after *i*, or nil.
      private def next_shown(i : Int32) : Int32?
        ((i + 1)...@panes.size).find { |j| shown?(j) }
      end

      # Makes the extent every shown pane has the one it wants (Qt's
      # `storeSizes`), after a move by hand.
      private def store_sizes : Nil
        @panes.each_index { |i| @wanted[i] = @fitted[i] if shown?(i) }
      end

      # Whether pane *i* stretches: it has a factor, or no pane has one.
      private def stretching?(i : Int32, stretch_all : Bool) : Bool
        stretch_all || @stretch[i] != 0
      end

      # The weight of pane *i* in the fit: the extent it wants, or *even* for
      # a pane never sized.
      private def weight(i : Int32, even : Int32) : Int32
        @wanted[i] > 0 ? @wanted[i] : even
      end

      # Fits the shown panes' wanted extents into *total* (Qt's `doResize`,
      # in cells), into `@fitted`: the dividers take one cell each, a pane
      # without a stretch factor the extent it wants, and the stretching panes
      # share the rest in proportion to theirs — every pane at least one cell.
      # With no factors set all panes stretch; when the fixed panes alone
      # would not leave the stretching ones a cell each, all stretch too,
      # shrinking in proportion rather than any collapsing. A pane never sized
      # weighs as much as the average sized stretching pane, or one when there
      # is none. The division's leftover goes to the last stretching pane.
      private def fit(total : Int32) : Nil
        @panes.each_index { |i| @fitted[i] = 0 }
        shown = shown_count
        return if shown == 0
        available = Math.max(shown, total - (shown - 1))

        stretch_all = @stretch.all?(&.zero?)
        sum = 0
        sized = 0
        @panes.each_index do |i|
          next unless shown?(i) && @wanted[i] > 0 && stretching?(i, stretch_all)
          sum += @wanted[i]
          sized += 1
        end
        even = sized > 0 ? Math.max(1, sum // sized) : 1

        fixed = 0
        weights = 0
        stretching = 0
        @panes.each_index do |i|
          next unless shown?(i)
          if stretching?(i, stretch_all)
            weights += weight(i, even)
            stretching += 1
          else
            fixed += weight(i, even)
          end
        end
        if stretching == 0 || available - fixed < stretching
          stretch_all = true
          weights += fixed
          fixed = 0
        end

        room = available - fixed
        remainder = room
        last = -1
        @panes.each_index do |i|
          next unless shown?(i)
          if stretching?(i, stretch_all)
            @fitted[i] = Math.max(1, room * weight(i, even) // weights)
            remainder -= @fitted[i]
            last = i
          else
            @fitted[i] = weight(i, even)
          end
        end
        if remainder > 0
          @fitted[last] += remainder
        else
          # The one-cell floors overdrew: the cells come off the widest panes.
          while remainder < 0
            widest = -1
            @panes.each_index do |i|
              next unless shown?(i) && stretching?(i, stretch_all) && @fitted[i] > 1
              widest = i if widest < 0 || @fitted[i] > @fitted[widest]
            end
            break if widest < 0
            @fitted[widest] -= 1
            remainder += 1
          end
        end
      end

      # Places the shown panes one after another, each at the extent `#fit`
      # gave it, with a divider between neighbors; a hidden pane is skipped
      # and its divider hidden, as is the last shown pane's.
      private def relayout
        return if @panes.empty?
        total = total_span
        return if total <= 0
        fit total

        n = @panes.size
        last = @panes.rindex { |pane| !pane.hidden? } || -1
        cursor = 0
        @panes.each_with_index do |pane, i|
          if shown?(i)
            place_pane pane, cursor, @fitted[i], last: i == last
            cursor += @fitted[i]
          end
          next if i == n - 1
          @positions[i] = cursor
          div = @dividers[i]
          if shown?(i) && i != last
            place_divider div, cursor
            div.show
            cursor += 1
          else
            div.hide
          end
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
