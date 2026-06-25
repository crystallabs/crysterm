module Crysterm
  class Widget
    # Is element scrollable?
    property? scrollable = false

    # Whether the widget position is fixed even in presence of scroll?
    # (Primary use in widget labels, which are always e.g. on top-left, and the
    # scrollbar widget, which must not scroll away with the content it tracks.)
    property? fixed = false

    # When a scrollable widget shows its scroll bar — Qt's `Qt::ScrollBarPolicy`.
    enum ScrollBarPolicy
      # Show the bar only while the content overflows the viewport (Qt default).
      AsNeeded
      # Always reserve and show the bar.
      AlwaysOn
      # Never show the bar.
      AlwaysOff
    end

    # When this widget's scroll bar chrome is shown (per-axis vertical for now;
    # horizontal lands with horizontal scrolling). Base widgets default to
    # `AlwaysOff` (opt-in, as before); scrollable widgets override to `AsNeeded`.
    property scrollbar_policy : ScrollBarPolicy = ScrollBarPolicy::AlwaysOff

    # Whether the scroll bar is enabled at all (i.e. the policy is not
    # `AlwaysOff`). Back-compat alias for the former `scrollbar : Bool`.
    def scrollbar? : Bool
      !scrollbar_policy.always_off?
    end

    # Back-compat sugar for the former `scrollbar : Bool`: `true` ⇒ `AsNeeded`,
    # `false` ⇒ `AlwaysOff`.
    def scrollbar=(v : Bool) : Bool
      @scrollbar_policy = v ? ScrollBarPolicy::AsNeeded : ScrollBarPolicy::AlwaysOff
      v
    end

    # Qt `QAbstractScrollArea#verticalScrollBarPolicy`: an alias of
    # `#scrollbar_policy` (the only axis wired today).
    def vertical_scrollbar_policy : ScrollBarPolicy
      scrollbar_policy
    end

    # :ditto:
    def vertical_scrollbar_policy=(p : ScrollBarPolicy) : ScrollBarPolicy
      self.scrollbar_policy = p
    end

    # Qt `QAbstractScrollArea#horizontalScrollBarPolicy`. Stored now for API
    # shape, but not yet consulted — horizontal scrolling lands with workstream D.
    property horizontal_scrollbar_policy : ScrollBarPolicy = ScrollBarPolicy::AlwaysOff

    # Whether the scroll bar chrome should be shown right now, given the policy
    # and current content: never when non-scrollable or `AlwaysOff`, always
    # under `AlwaysOn`, and only on overflow under `AsNeeded`.
    def show_scrollbar? : Bool
      policy_shows?(scrollbar_policy) { really_scrollable? }
    end

    # Horizontal counterpart of `#show_scrollbar?`, keyed off
    # `#horizontal_scrollbar_policy` and horizontal overflow.
    def show_horizontal_scrollbar? : Bool
      policy_shows?(horizontal_scrollbar_policy) { really_scrollable_x? }
    end

    # Rows reserved at the bottom for a shown horizontal scroll bar, so content
    # and vertical-scroll math don't run underneath it — the horizontal analogue
    # of the column the vertical bar reserves in `_wrap_content`. `0` (no effect)
    # unless the bar is actually shown, so widgets without a horizontal bar are
    # unaffected.
    def hscrollbar_rows : Int32
      show_horizontal_scrollbar? ? 1 : 0
    end

    # Whether a bar with *policy* should show: never when non-scrollable or
    # `AlwaysOff`, always under `AlwaysOn`, and under `AsNeeded` only when the
    # yielded overflow test is true. The block is `yield`ed (inlined, no closure).
    private def policy_shows?(policy : ScrollBarPolicy, &) : Bool
      return false unless scrollable?
      case policy
      in .always_off? then false
      in .always_on?  then true
      in .as_needed?  then yield
      end
    end

    # The `Widget::ScrollBar` child rendering this widget's scrollbar, created
    # lazily by `#ensure_scrollbar_widget` (`nil` until first shown). Precursor
    # to Qt's `verticalScrollBar()` accessor.
    getter scrollbar_widget : ScrollBar?

    # The horizontal `Widget::ScrollBar` child, once horizontal scrolling
    # (workstream D) exists. Always `nil` for now.
    getter horizontal_scrollbar_widget : ScrollBar?

    # Called each render to reconcile the scroll bar chrome with the policy:
    # create+show+sync the bar when `#show_scrollbar?`, hide (never destroy) it
    # otherwise so it can reappear without losing state. Idempotent.
    protected def update_scrollbar_widget : Nil
      if show_scrollbar?
        ensure_scrollbar_widget.show
      else
        @scrollbar_widget.try &.hide
      end

      if show_horizontal_scrollbar?
        ensure_horizontal_scrollbar_widget.show
      else
        @horizontal_scrollbar_widget.try &.hide
      end
    end

    # Lazily create a real `Widget::ScrollBar` child — `fixed` (exempt from this
    # widget's scroll), pinned to the right interior edge, and `#attach`ed so it
    # reflects/drives the scroll position. It then renders and handles
    # interaction like any widget (and is styleable via CSS, e.g.
    # `ScrollBar { color: … }` / `.scrollbar { … }`). Idempotent; returns the bar.
    protected def ensure_scrollbar_widget : ScrollBar
      sb = @scrollbar_widget ||= bind_scrollbar ScrollBar.new parent: self,
        orientation: :vertical, top: 0, right: 0, width: 1, height: "100%"
      sb.sync_from_target
      sb
    end

    # Horizontal counterpart of `#ensure_scrollbar_widget`: a real horizontal
    # `Widget::ScrollBar` child, `fixed` at the bottom interior edge and bound to
    # this widget's x-axis. Idempotent; returns the bar.
    protected def ensure_horizontal_scrollbar_widget : ScrollBar
      sb = @horizontal_scrollbar_widget ||= bind_scrollbar ScrollBar.new parent: self,
        orientation: :horizontal, left: 0, bottom: 0, height: 1, width: "100%"
      sb.sync_from_target
      sb
    end

    # Common chrome setup shared by both `ensure_*` accessors: makes *sb* `fixed`
    # (exempt from this widget's scroll), `.scrollbar`-classed, and `#attach`ed so
    # it reflects/drives the scroll position. Returns *sb*.
    private def bind_scrollbar(sb : ScrollBar) : ScrollBar
      sb.fixed = true
      sb.add_css_class "scrollbar"
      sb.attach self
      sb
    end

    # --- Qt `QAbstractScrollArea` facade ------------------------------------
    # Thin, Qt-shaped accessors over the baked-in scroll machinery. The widget
    # itself is the scroll area; its content area is the implicit `viewport()`.

    # Qt's `verticalScrollBar()`: the bound vertical `ScrollBar`, created on
    # first access (like Qt, the object exists even when the policy hides it).
    def vertical_scrollbar : ScrollBar
      ensure_scrollbar_widget
    end

    # Qt's `horizontalScrollBar()`: the bound horizontal `ScrollBar`, created on
    # first access (like Qt, the object exists even when the policy hides it).
    def horizontal_scrollbar : ScrollBar
      ensure_horizontal_scrollbar_widget
    end

    # Qt's `scrollContentsBy(dx, dy)`: scroll the viewport by *dy* lines
    # (vertical) and *dx* columns (horizontal).
    def scroll_contents_by(dx : Int32, dy : Int32) : Nil
      scroll dy unless dy == 0
      scroll_x dx unless dx == 0
    end

    # Qt's `ensureVisible(y, margin)`: scroll the minimum amount so content line
    # *y* sits within the viewport (optionally keeping *margin* lines of context
    # on the leading/trailing edge). No-op when already visible. Generalizes the
    # `scroll_to @selected` pattern used by `List`/`Tree`. Returns whether the
    # viewport moved.
    def ensure_visible(y : Int32, margin : Int32 = 0) : Bool
      return false unless scrollable?
      visible = aheight - iheight - hscrollbar_rows
      return false if visible <= 0

      base = @child_base
      if y < @child_base + margin
        @child_base = y - margin
      elsif y > @child_base + visible - 1 - margin
        @child_base = y - (visible - 1) + margin
      end
      @child_base = @child_base.clamp(0, Math.max(0, get_scroll_height - visible))

      return false if @child_base == base
      mark_dirty
      emit Crysterm::Event::Scroll, @child_base - base
      true
    end

    # Qt's `ensureWidgetVisible(child, margin)`: scroll so descendant *child* is
    # within the viewport. Reveals the bottom edge first, then the top, so the
    # top wins when the child is taller than the viewport.
    def ensure_widget_visible(child : Widget, margin : Int32 = 0) : Bool
      moved = ensure_visible(child.rtop + child.aheight - 1, margin)
      ensure_visible(child.rtop, margin) || moved
    end

    # Horizontal counterpart of `#ensure_visible`: scroll the column window the
    # minimum amount so content column *x* sits within the viewport. No-op when
    # already visible or not horizontally scrollable. Returns whether the view
    # moved.
    def ensure_visible_x(x : Int32, margin : Int32 = 0) : Bool
      return false unless scrollable?
      visible = content_width
      return false if visible <= 0

      base = @child_base_x
      if x < @child_base_x + margin
        @child_base_x = x - margin
      elsif x > @child_base_x + visible - 1 - margin
        @child_base_x = x - (visible - 1) + margin
      end
      @child_base_x = @child_base_x.clamp(0, Math.max(0, get_scroll_width - visible))

      return false if @child_base_x == base
      mark_dirty
      emit Crysterm::Event::Scroll, @child_base_x - base, Tput::Orientation::Horizontal
      true
    end

    # ------------------------------------------------------------------------

    # Should widget indicate the scroll position?
    property? track : Bool = false

    # Offset from the top of content (in number of lines) due to scrolling.
    # E.g. 0 == no scroll (first line is visible/shown at the top), or
    # 5 == 5 lines are hidden due to scroll, 6th line of content is first to
    # be displayed.
    property child_base = 0

    # Offset of cursor (in number of lines) within Widget. Value of 0 means
    # cursor being at first line of visible (potentially scrolled) content.
    property child_offset = 0

    # Horizontal counterparts of `child_base`/`child_offset`, in display columns
    # (the x-axis). `child_base_x` is the first visible column of (non-wrapped)
    # content; `child_offset_x` mirrors `child_offset` for symmetry but the
    # generic path keeps it 0, so `get_scroll_x == child_base_x`. Only meaningful
    # when `wrap_content?` is off — wrapped content never overflows horizontally.
    property child_base_x = 0

    # :ditto:
    property child_offset_x = 0

    property base_limit = Int32::MAX

    property? always_scroll : Bool = false

    @ev_label_scroll : Crysterm::Event::Scroll::Wrapper?

    # Potentially use this where ever .scrollable? is used
    def really_scrollable?
      return @scrollable if @resizable
      get_scroll_height > aheight
    end

    # Returns total amount of lines by which widget is scrolled.
    #
    # The value combines invisible and visible parts. E.g. if a widget is scrolled
    # by 6 lines which are invisible (out of screen), and the cursor is at the 5th
    # line of visible content, `get_scroll` will return 11.
    def get_scroll
      @child_base + @child_offset
    end

    def scroll_to(offset, always = false)
      scroll 0
      scroll offset - (@child_base + @child_offset), always
    end

    def get_scroll_height
      Math.max @_clines.size, _scroll_bottom
    end

    # --- horizontal axis ----------------------------------------------------

    # Combined horizontal scroll position, in columns (mirrors `#get_scroll`).
    def get_scroll_x
      @child_base_x + @child_offset_x
    end

    # Widest content row, in display columns — the horizontal analogue of
    # `#get_scroll_height`. Computed by `_wrap_content` (the longest *unclipped*
    # line); `0` for wrapped content, which never overflows horizontally.
    def get_scroll_width
      @_clines.full_width
    end

    # Columns reserved at the right of the content area beyond border/padding —
    # the vertical scroll bar's column when shown. `_wrap_content` subtracts this
    # (so wrapped/clipped content avoids the bar), and the horizontal-scroll math
    # uses it via `#content_width`, keeping the two in agreement. Subclasses add
    # their own reservations (`PlainTextEdit`'s end-of-line caret column).
    def content_margin_x : Int32
      show_scrollbar? ? 1 : 0
    end

    # Width in columns actually available to content: the viewport minus
    # border/padding (`iwidth`) and the reserved right-edge columns
    # (`content_margin_x`). The horizontal analogue of the visible content
    # height, used for the horizontal scroll extent and bar range so the last
    # columns are reachable rather than hidden behind the reserved margin.
    def content_width : Int32
      Math.max 0, awidth - iwidth - content_margin_x
    end

    # Whether content overflows the viewport horizontally (so an `AsNeeded`
    # horizontal bar should show). Always false while wrapping, since wrapped
    # content is reflowed to fit the width.
    def really_scrollable_x?
      return false if wrap_content?
      get_scroll_width > content_width
    end

    # Horizontal counterpart of `#scroll`: shift the visible column window by
    # *offset* columns, clamped to the content width, and repaint. Emits
    # `Event::Scroll` carrying the signed column delta and `:horizontal`.
    def scroll_x(offset = 1)
      return unless @scrollable && screen?
      visible = content_width
      return if visible <= 0

      base = @child_base_x
      @child_offset_x = 0
      @child_base_x = (base + offset).clamp(0, Math.max(0, get_scroll_width - visible))
      return if @child_base_x == base

      mark_dirty
      emit Crysterm::Event::Scroll, @child_base_x - base, Tput::Orientation::Horizontal
    end

    # Horizontal counterpart of `#scroll_to`: move the column window so its left
    # edge sits at *offset*.
    def scroll_x_to(offset)
      scroll_x offset - get_scroll_x
    end

    def set_scroll_perc(i)
      m = get_scroll_height
      scroll_to ((i / 100) * m).to_i
    end

    def reset_scroll
      return unless @scrollable
      prev = @child_base + @child_offset
      @child_offset = 0
      @child_base = 0
      @child_offset_x = 0
      @child_base_x = 0
      mark_dirty
      emit Crysterm::Event::Scroll, -prev
    end

    def get_scroll_perc(s)
      # `_get_coords` (method call), not `@_get_coords` (a nonexistent ivar).
      pos = @lpos || _get_coords
      if !pos
        return s ? -1 : 0
      end

      height = (pos.yl - pos.yi) - iheight - hscrollbar_rows
      i = get_scroll_height
      # p

      if height < i
        if @always_scroll
          p = @child_base / (i - height)
        else
          p = (@child_base + @child_offset) / (i - 1)
        end
        return p * 100
      end

      s ? -1 : 0
    end

    def _scroll_bottom
      return 0 unless @scrollable

      # We could just calculate the children, but we can
      # optimize for lists by just returning the items.length.
      if @_is_list
        return @items.any? ? @items.size : 0
      end

      @lpos.try do |lpos|
        if lpos._scroll_bottom != 0
          return lpos._scroll_bottom
        end
      end

      bottom = @children.reduce(0) do |current, el|
        # `fixed` children are chrome, not scrollable content — the scroll bars
        # (pinned to the right/bottom edge) and labels. Counting them inflated the
        # scroll height to ~the viewport height, which (e.g.) kept a `PlainTextEdit`'s
        # vertical bar stuck on after its content shrank back to a single line.
        next current if el.fixed?

        # el.aheight alone does not calculate the shrunken height, we need to use
        # get_coords. A shrunken box inside a scrollable element will not grow any
        # larger than the scrollable element's context regardless of how much
        # content is in the shrunken box, unless we do this (call get_coords
        # without the scrollable calculation):
        # See: $ test/widget-shrink-fail-2
        el_bottom = if el.screen? && (lpos = el._get_coords false, true)
                      el.rtop + (lpos.yl - lpos.yi)
                    else
                      el.rtop + el.aheight
                    end
        Math.max current, el_bottom
      end

      # XXX Use this? Makes .get_scroll_height useless
      # if bottom < @_clines.size
      #   bottom = @_clines.size
      # end

      @lpos.try do |lpos|
        lpos._scroll_bottom = bottom
      end

      bottom
    end

    # Scrolls widget by `offset` lines down or up
    def scroll(offset = 1, always = false)
      return unless @scrollable
      return unless screen?

      # A scroll shifts the whole viewport, so the subtree must be repainted.
      mark_dirty

      # Handle scrolling.
      # visible == amount of actual content lines visible in the widget. E.g. for
      # a widget of height=4 and border (which renders within height), the amount
      # of visible lines == 2. A shown horizontal bar reserves the bottom row.
      visible = aheight - iheight - hscrollbar_rows
      # Current scrolling amount, i.e. the index of the first line of content which
      # is actually shown. (base == 2 means content is showing from its 3rd line onwards)
      base = @child_base
      # Combined position before the move, so `Event::Scroll` can report the
      # signed delta (`get_scroll` shifts by both base and offset changes).
      before = @child_base + @child_offset

      if @always_scroll || always
        # Semi-workaround
        @child_offset = offset > 0 ? visible - 1 + offset : offset
      else
        @child_offset += offset
      end

      if @child_offset > visible - 1
        d = @child_offset - (visible - 1)
        @child_offset -= d
        @child_base += d
      elsif @child_offset < 0
        d = @child_offset
        @child_offset += -d
        @child_base += d
      end

      clamp_child_base

      # Find max "bottom" value for
      # content and descendant elements.
      # Scroll the content if necessary.
      if @child_base == base
        return emit Crysterm::Event::Scroll, (@child_base + @child_offset) - before
      end

      # When scrolling text, we want to be able to handle SGR codes as well as line
      # feeds. This allows us to take preformatted text output from other programs
      # and put it in a scrollable text box.
      process_content

      clamp_child_base_to_content

      # Optimize scrolling with CSR + IL/DL.
      p = @lpos
      # Only really need _get_coords() if we want
      # to allow nestable scrolling elements...
      # or if we **really** want shrinkable
      # scrolling elements.
      # p = _get_coords
      if p && (@child_base != base) && screen.clean_sides(self)
        t = p.yi + itop
        b = p.yl - ibottom - 1
        d = @child_base - base

        if d > 0 && d < visible
          # scrolled down
          screen.delete_line(d, t, t, b)
        elsif d < 0 && -d < visible
          # scrolled up
          d = -d
          screen.insert_line(d, t, t, b)
        end
      end

      emit Crysterm::Event::Scroll, (@child_base + @child_offset) - before
    end

    # Clamps `@child_base` into the valid `[0, @base_limit]` range. Kept as an
    # explicit branch (rather than `.clamp`) so it never raises even if
    # `@base_limit` is set below 0, exactly matching the original inline form.
    private def clamp_child_base
      if @child_base < 0
        @child_base = 0
      elsif @child_base > @base_limit
        @child_base = @base_limit
      end
    end

    # Pulls `@child_base` down to the largest valid scroll offset for the current
    # content — the greater of the wrapped-content height (`@_clines.size`) and
    # the descendant extent (`_scroll_bottom`), each measured against the visible
    # inner height — then re-clamps into `[0, @base_limit]`. Shared by `#scroll`
    # and `#_recalculate_index`, which had identical copies of this.
    private def clamp_child_base_to_content
      visible = aheight - iheight - hscrollbar_rows

      max = @_clines.size - visible
      max = 0 if max < 0
      emax = _scroll_bottom - visible
      emax = 0 if emax < 0

      @child_base = Math.min @child_base, Math.max(emax, max)

      clamp_child_base
    end

    def _recalculate_index
      return 0 if !screen? || !@scrollable

      clamp_child_base_to_content
    end
  end
end
