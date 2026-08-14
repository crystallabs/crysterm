require "./box"
require "../mixin/nav_keys"

module Crysterm
  class Widget
    # Vertically-cycling carousel of variable-height cards — notcurses'
    # `ncreel` analogue.
    #
    # A `Reel` holds an ordered ring of `Tablet`s (each a `Box`, free to carry
    # its own content, style and children). One tablet is *focused*: it is
    # always fully visible, its neighbors fill the remaining rows above and
    # below in ring order, and tablets at the edges clip against the reel's
    # bounds (`overflow: Hidden`). With `circular` (the default) focus
    # rotation wraps at both ends and the layout wraps tablets around the
    # ring to fill both sides of the focused one; without it the reel stops
    # at the first/last tablet.
    #
    # Each tablet's height is its `Tablet#rows` when set (also captured from
    # an explicit `height:` at construction); otherwise it is measured from
    # the tablet's wrapped content each layout pass.
    #
    # With `keys: true`, Up/Down (and, with `vi_keys: true`, `k`/`j`) move
    # focus by one tablet, and Home/End (`g`/`G`) jump to the first/last.
    # Clicking a tablet focuses it. Emits `Event::ItemAdded`,
    # `Event::ItemRemoved`, and `Event::CurrentChanged` (the focused index,
    # `-1` when the reel empties), matching the other item containers.
    #
    # ```
    # reel = Widget::Reel.new parent: window, width: 30, height: 12, keys: true
    # reel.add_tablet "First card"
    # reel.add_tablet "Tall card", rows: 5
    # reel.focus_next
    # ```
    class Reel < Box
      include Mixin::NavKeys

      # One card of a `Reel` — a `Box` whose height the reel manages.
      class Tablet < Box
        # Fixed height in rows; `nil` measures the wrapped content instead.
        # An explicit `height:` given at construction is captured here, so it
        # survives the reel's per-frame `height=` assignments.
        property rows : Int32?

        # The tablet's "click → focus me" subscription, re-armed by the owning
        # reel on add and dropped on remove (the `Subscription` idiom of
        # `ToolBox::Item#click`).
        getter click = Subscription.new

        def initialize(rows : Int32? = nil, **box)
          super **box
          @rows = rows || @height.as?(Int32)
        end

        # Rows this tablet wants at *outer_width* (the reel's inner width):
        # `#rows` when fixed, else the wrapped content height plus this
        # tablet's own border/padding. Never less than 1.
        protected def reel_rows(outer_width : Int32) : Int32
          if r = @rows
            return Math.max r, 1
          end
          process_content awidth_hint: outer_width
          Math.max _clines.size + ivertical, 1
        end
      end

      # Partially visible tablets must clip at this widget's bounds rather
      # than paint outside it.
      @overflow = Overflow::Hidden

      # The tablets, in ring order. Read-only — add via `#add_tablet`.
      getter tablets = [] of Tablet

      # Index of the focused tablet (`-1` while the reel is empty). Assigning
      # moves focus and emits `Event::CurrentChanged`; out of range is a no-op.
      getter focused_index : Int32 = -1

      # Whether focus rotation (and the layout's fill of leftover space)
      # wraps around the ends of the ring.
      property? circular : Bool

      # Top row of the focused tablet within the content area, persisted
      # across layout passes so the reel rolls around a stable focus position
      # instead of re-deriving it each frame.
      @focused_top = 0

      # `#relayout` scratch (per-tablet heights / placed flags), reused across
      # frames — relayout runs on every paint, so per-call arrays would
      # allocate per frame. Valid only within one `#relayout` call.
      @heights_scratch = [] of Int32
      @placed_scratch = [] of Bool

      def initialize(@circular : Bool = true, **box)
        super **box

        if @keys
          on ::Crysterm::Event::KeyPress, ->handle_key_press(::Crysterm::Event::KeyPress)
        end
      end

      # Number of tablets.
      def count : Int32
        @tablets.size
      end

      # The tablet at *index*, or `nil` when out of range.
      def tablet(index : Int) : Tablet?
        return if index < 0
        @tablets[index]?
      end

      # The focused tablet, or `nil` while the reel is empty.
      def focused_tablet : Tablet?
        return if @focused_index < 0
        @tablets[@focused_index]?
      end

      # Adds *tablet* to the ring — after/before the given neighbor when one
      # is passed (an absent neighbor appends), at the end otherwise. The
      # first tablet added becomes focused. Emits `Event::ItemAdded`. Returns
      # the tablet.
      def add_tablet(tablet : Tablet, *, after : Tablet? = nil, before : Tablet? = nil) : Tablet
        i = if after && (ai = @tablets.index(after))
              ai + 1
            elsif before && (bi = @tablets.index(before))
              bi
            else
              @tablets.size
            end

        # Tablets span the reel's full inner width; only top/height are laid
        # out per frame.
        tablet.left = 0
        tablet.right = 0

        @tablets.insert i, tablet
        append tablet

        # Keyed on the tablet's identity (not a captured index), so removals
        # never leave a stale index behind.
        tablet.click.on(tablet, ::Crysterm::Event::Click) do
          if ci = @tablets.index(tablet)
            self.focused_index = ci
          end
        end

        if @focused_index < 0
          @focused_index = 0
          emit ::Crysterm::Event::CurrentChanged, 0
        elsif i <= @focused_index
          # The insertion shifted the focused tablet by one; follow it without
          # announcing a change that didn't happen.
          @focused_index += 1
        end

        emit ::Crysterm::Event::ItemAdded
        request_render
        tablet
      end

      # Builds a `Tablet` from *content* (fixed at *rows* rows when given,
      # content-measured otherwise) and adds it — see the `Tablet` overload.
      def add_tablet(content : String = "", rows : Int32? = nil, *, after : Tablet? = nil, before : Tablet? = nil, style : Style? = nil) : Tablet
        add_tablet Tablet.new(rows: rows, content: content, style: style), after: after, before: before
      end

      # Removes *tablet* from the ring, detaching (not destroying) it, and
      # returns it — or `nil` when it is not in this reel. Keeps a valid
      # focused tablet and emits `Event::ItemRemoved`. Thin like
      # `ToolBox#remove_item`: the bookkeeping lives in the `#remove` override
      # so every detach path shares it.
      def remove_tablet(tablet : Tablet) : Tablet?
        return unless @tablets.includes? tablet
        remove tablet
        tablet
      end

      # :ditto:, addressing the tablet by *index*.
      def remove_tablet(index : Int) : Tablet?
        if t = tablet(index)
          remove_tablet t
        end
      end

      # Catches a tablet detached by any path — `#remove_tablet`, a direct
      # `tablet.destroy` or `#detach_from_tree`, a bare `#remove` — and keeps
      # the ring/focus in sync. Non-tablet children pass straight through.
      def remove(element)
        idx = element.is_a?(Tablet) ? @tablets.index(element) : nil
        kept = focused_tablet
        super
        return unless idx
        t = @tablets.delete_at idx
        t.click.off
        reclamp_focus idx, kept
        emit ::Crysterm::Event::ItemRemoved
        request_render
      end

      # :ditto: — moves focus to *index*.
      def focused_index=(index : Int) : Nil
        return unless 0 <= index < @tablets.size
        return if index == @focused_index
        anchor_focus_top index
        @focused_index = index.to_i
        emit ::Crysterm::Event::CurrentChanged, @focused_index
        request_render
      end

      # Moves focus to the next tablet in ring order, wrapping past the last
      # when `circular?` (a no-op at the end otherwise).
      def focus_next : Nil
        n = @tablets.size
        return if n == 0
        if @focused_index < n - 1
          self.focused_index = @focused_index + 1
        elsif @circular
          self.focused_index = 0
        end
      end

      # Moves focus to the previous tablet in ring order, wrapping past the
      # first when `circular?` (a no-op at the start otherwise).
      def focus_previous : Nil
        n = @tablets.size
        return if n == 0
        if @focused_index > 0
          self.focused_index = @focused_index - 1
        elsif @circular
          self.focused_index = n - 1
        end
      end

      # :ditto:
      def focus_prev : Nil
        focus_previous
      end

      # Relayout on every paint: tablet heights and the visible window depend
      # on the widget's resolved size, only known once coordinates are
      # computed (the `ToolBox#render` pattern).
      def render(with_children = true)
        relayout
        super
      end

      def handle_key_press(e)
        case nav_intent(e)
        when .backward? then focus_previous
        when .forward?  then focus_next
        when .first?    then self.focused_index = 0
        when .last?     then self.focused_index = @tablets.size - 1
        else
          return
        end
        e.accept
        request_render
      end

      # Restores a valid focus after the tablet at *removed_index* left the
      # ring: the surviving previously-focused *kept* tablet stays focused at
      # its shifted index, else the neighbor that slid into the vacated slot
      # takes over; an emptied reel drops to the `-1` sentinel. Announces the
      # outcome via `Event::CurrentChanged` either way, mirroring
      # `Mixin::PagedContainer#reclamp_after_removal`.
      private def reclamp_focus(removed_index : Int32, kept : Tablet?) : Nil
        if @tablets.empty?
          @focused_index = -1
          emit ::Crysterm::Event::CurrentChanged, -1
        else
          ni = (kept ? @tablets.index(kept) : nil) || removed_index.clamp(0, @tablets.size - 1)
          @focused_index = ni
          emit ::Crysterm::Event::CurrentChanged, ni
        end
      end

      # Re-anchors `@focused_top` at the newly focused tablet's current
      # on-screen top, so focus rotation rolls the ring around a stationary
      # focus position. An off-screen tablet keeps the current anchor (it
      # surfaces where the old focus was); `#relayout` clamps either way.
      private def anchor_focus_top(index : Int32) : Nil
        t = @tablets[index]
        if t.visible? && (tt = t.top.as?(Int32))
          @focused_top = Math.max tt, 0
        end
      end

      # Positions the ring for this frame. When everything fits, the tablets
      # simply stack from the top. Otherwise the focused tablet is pinned
      # fully visible at (a clamped) `@focused_top`, successors fill the rows
      # below and predecessors the rows above — each side wrapping around the
      # ring when `circular?`, every tablet placed at most once — and the
      # tablets that found no room are hidden.
      private def relayout : Nil
        n = @tablets.size
        return if n == 0
        inner = (aheight - ivertical) rescue (height.as?(Int32) || n)
        return if inner <= 0
        outer_w = (awidth - ihorizontal) rescue 0

        f = @focused_index.clamp(0, n - 1)
        heights = @heights_scratch
        heights.clear
        @tablets.each { |t| heights << t.reel_rows(outer_w) }
        total = heights.sum

        if total <= inner
          y = 0
          @tablets.each_with_index do |t, i|
            @focused_top = y if i == f
            place t, y, heights[i]
            y += heights[i]
          end
          return
        end

        h_f = Math.min heights[f], inner
        desired = @focused_top.clamp(0, inner - h_f)
        unless @circular
          # Without wraparound, leftover rows can't be filled from the other
          # end of the ring, so pull the focus position in far enough that
          # neither edge shows a blank band while tablets remain unshown.
          sum_above = (0...f).sum { |i| heights[i] }
          hi = Math.min(inner - h_f, sum_above)
          lo = Math.max(0, inner - (total - sum_above))
          desired = desired.clamp(lo, hi)
        end

        placed = @placed_scratch
        placed.clear
        n.times { placed << false }
        place @tablets[f], desired, heights[f]
        placed[f] = true

        y = desired + heights[f]
        i = f
        while y < inner
          i += 1
          i -= n if @circular && i >= n
          break if i >= n || placed[i]
          place @tablets[i], y, heights[i]
          placed[i] = true
          y += heights[i]
        end

        y = desired
        i = f
        while y > 0
          i -= 1
          i += n if @circular && i < 0
          break if i < 0 || placed[i]
          y -= heights[i]
          place @tablets[i], y, heights[i]
          placed[i] = true
        end

        @tablets.each_with_index do |t, ti|
          t.hide unless placed[ti]
        end
        @focused_top = desired
      end

      private def place(t : Tablet, y : Int32, rows : Int32) : Nil
        t.top = y
        t.height = rows
        t.show
      end
    end
  end
end
