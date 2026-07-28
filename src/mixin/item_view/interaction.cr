module Crysterm
  module Mixin
    module ItemView
      # When true, a single mouse click on an item activates it (rather than the
      # default two-click select-then-activate).
      property? activate_on_click : Bool = false

      # When true, moving the pointer over a row selects it (no click required),
      # like desktop menus. Off for plain lists. Per-row hook is `#hover_item`.
      property? hover_select : Bool = false

      # Hook invoked when the pointer moves onto item *i* and `#hover_select?` is
      # on. *i* is the item's absolute index — hit-testing runs against painted
      # geometry, so a scrolled list reports the real entry under the pointer, not
      # a viewport row — and selecting it directly is correct at any scroll
      # offset. The clamp to the visible window only guards the fringe where an
      # item box painted at the viewport's edge stays hit-testable one row past
      # the last fully-shown row, so a hover there parks on the last visible entry
      # instead of jumping to an off-screen one. Overridable (e.g. to open/close
      # submenus).
      def hover_item(i : Int)
        vis = visible_content_rows
        vis = 1 if vis < 1
        # Clamp to the visible *item* range: `@child_base`/`vis` are content rows,
        # so with `item_spacing > 0` a bare `clamp(@child_base, …)` would compare
        # an item index against row bounds and snap a legitimately-visible item to
        # a different one. Convert the row bounds to item indices first.
        self.current_index = i.clamp(item_at_row(@child_base), item_at_row(@child_base + vis - 1))
      end

      # Moves the selection by *delta* rows (negative = up), through
      # `#current_index=` so it clamps and steps over dividers.
      def move_selection(delta : Int32)
        self.current_index = @selected + delta
      end

      # Handles one mouse-wheel notch (*dir* is `-1` up / `+1` down). Branches on
      # `#wheel_mode`: `MoveSelection` (default) treats the wheel like the arrow
      # keys — two rows per notch, scrolling only to keep the selection visible;
      # `ScrollViewUnderPointer` scrolls the viewport under a stationary pointer
      # (drop-downs), keeping the selection on the entry under the cursor.
      def wheel_scroll(dir : Int32) : Nil
        if @wheel_mode.scroll_view_under_pointer?
          scroll_view_under_pointer dir
        else
          move_selection dir * 2
        end
      end

      # The `ScrollViewUnderPointer` body. Shifts the viewport one row
      # (`#child_base`) and re-selects whatever entry lands under the cursor —
      # i.e. the selection's current viewport row (`@child_offset`, which
      # `#hover_item` keeps pinned to the pointer). Wheel and hover-select must
      # agree on the single rule "selected == entry under the cursor", or the
      # wheel nudges the selection only for the next hover to snap it back. At the
      # top/bottom edges, where the view can no longer scroll, it steps the
      # selection within the visible page so the first/last entries stay reachable
      # by the wheel alone.
      private def scroll_view_under_pointer(dir : Int32) : Nil
        return if dir == 0 || @item_boxes.empty?
        step = dir > 0 ? 1 : -1
        visible = visible_content_rows
        visible = 1 if visible < 1
        # The scrollable extent is in content *rows* (`scroll_height` includes
        # the inter-item gaps); `@item_boxes.size - visible` under-counts a spaced list
        # and stops the wheel short of the bottom.
        max_base = Math.max(0, scroll_height - visible)
        row = @child_offset # selection's viewport row == where the pointer hovered
        nb = (@child_base + step).clamp(0, max_base)
        if nb != @child_base
          @child_base = nb
          # `nb + row` is the content row under the cursor; map it back to the item
          # index there so a spaced list selects the right entry.
          self.current_index = item_at_row(nb + row).clamp(0, @item_boxes.size - 1)
        else
          self.current_index = (@selected + step).clamp(0, @item_boxes.size - 1)
        end
      end

      # Moves the selection up *offset* rows (thin wrapper over `#move_selection`).
      def up(offset : Int32 = 1)
        move_selection -offset
      end

      # Moves the selection down *offset* rows (thin wrapper over `#move_selection`).
      def down(offset : Int32 = 1)
        move_selection offset
      end

      # Enables the incremental-search prompt (`/` forward, `?` backward) in the
      # key handler.
      property? search = true

      # Lazily-created one-line input shown at the bottom of the window during a
      # search (see `#start_search`).
      @search_box : Widget::LineEdit? = nil

      # Index of the first item whose tag-stripped, case-insensitive text
      # contains *query*, scanning from the current selection and wrapping;
      # `nil` when nothing matches. `backward: true` searches upward.
      #
      # No match reports `nil`, not the current selection, which a caller could
      # not tell apart from a real hit on that same row (Qt's `findItems` likewise
      # reports an empty result rather than a fallback).
      def fuzzy_find(query : String, *, backward : Bool = false) : Int32?
        return if @item_boxes.empty?
        q = query.downcase
        n = @item_boxes.size
        step = backward ? -1 : 1
        i = @selected
        n.times do
          i = (i + step) % n
          return i if clean_tags(@ritems[i]).downcase.includes? q
        end
        nil
      end

      # The incremental-search `LineEdit` is a *window* child, a sibling of this
      # list — `Widget#destroy` only tears down this widget and its own children,
      # so the box must be dropped explicitly or it is orphaned at the window
      # bottom for the window's lifetime.
      def destroy
        Widget.destroy_satellite @search_box
        @search_box = nil
        super
      end

      private def ensure_search_box : Widget::LineEdit
        # The box is a *window* child: after this view is reparented to another
        # window, the memoized box is stranded on the old one and the prompt shows
        # (and reads keys) on the wrong window, leaving `/` search silently dead.
        # Drop the stale satellite and rebuild on this window.
        @search_box = refresh_satellite(@search_box)
        @search_box ||= begin
          box = Widget::LineEdit.new(
            window: window,
            bottom: 0, left: 0, right: 0, height: 1,
          )
          box.add_css_class "search" # themed via `.search { ... }`
          window.append box
          box.hide
          box
        end
      end

      # Opens the incremental-search prompt. Typing a query and pressing Enter
      # jumps to the next matching item; Escape cancels. `backward: true`
      # searches upward.
      def start_search(*, backward : Bool = false)
        return unless search?
        return if @item_boxes.empty?

        sb = ensure_search_box
        sb.set_label(backward ? "?" : "/")
        sb.value = ""
        sb.show
        request_render

        sb.read_input do |data|
          sb.hide
          focus
          # No match leaves the cursor where it was (`#fuzzy_find` reports `nil`
          # rather than the current selection, so there is nothing to move to).
          if data && !data.empty? && (hit = fuzzy_find(data, backward: backward))
            self.current_index = hit
          end
          request_render
        end
      end

      def on_keypress(e)
        visible = visible_content_rows
        # Half/page navigation steps by *items*, not rows: with `item_spacing > 0`
        # a page of `visible` rows holds only `items_per_page` items, so moving by
        # `visible` jumps ~two pages.
        per_page = items_per_page
        half = Math.max per_page // 2, 1

        # Vertical navigation (Up/Down/paging/Home-End + vi_keys k/j/g/G) is classified
        # once in `Mixin::NavKeys`; here each intent maps onto a selection move
        # rather than a viewport scroll.
        case nav_intent(e)
        when .backward?      then up
        when .forward?       then down
        when .first?         then self.current_index = 0
        when .last?          then self.current_index = @item_boxes.size - 1
        when .half_backward? then move_selection -half
        when .half_forward?  then move_selection half
        when .page_backward? then move_selection -per_page
        when .page_forward?  then move_selection per_page
        else
          case
          # vi_keys H/M/L target the item at the top/middle/bottom *row* of the
          # viewport; `@child_base` is a content row, so convert to an item index
          # (a bare `@child_base + …` would select a far-off item when spaced).
          when @vi_keys && e.char == 'H'
            self.current_index = item_at_row(@child_base)
          when @vi_keys && e.char == 'M'
            self.current_index = item_at_row(@child_base + visible // 2)
          when @vi_keys && e.char == 'L'
            self.current_index = item_at_row(@child_base + visible - 1)
          when search? && e.char == '/'
            start_search backward: false
          when search? && e.char == '?'
            start_search backward: true
          when multi_select? && e.char == ' '
            toggle_selection @selected
          when e.key == ::Tput::Key::Enter
            activate_current
          when e.key == ::Tput::Key::Escape
            cancel_current
          else
            return
          end
        end

        # Consume the key so it doesn't also drive an ancestor, and repaint.
        e.accept
        request_render
      end

      def on_resize(e)
        visible = visible_content_rows
        # Position against the selected item's *content row* (which includes the
        # inter-item gaps), not its bare index, or a spaced, overflowing list
        # parks the base `selected * item_spacing` rows above the item.
        row = item_row(@selected)
        if visible <= 0
          # Collapsed viewport (`ivertical >= aheight`, e.g. a bordered list
          # squeezed too small): the `else` branch would compute a negative
          # `@child_offset` and an out-of-range `@child_base`. Park the selection
          # at the base with a zero offset — a valid state for a list showing no
          # rows.
          @child_base = row
          @child_offset = 0
        elsif visible >= row + 1
          @child_base = 0
          @child_offset = row
        else
          @child_base = row - visible + 1
          @child_offset = visible - 1
        end
      end
    end
  end
end
