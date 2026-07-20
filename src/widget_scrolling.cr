module Crysterm
  class Widget
    # Is element scrollable?
    getter? scrollable = false

    # Once-flag: has the `Event::ContentParsed → reclamp_scroll_index` clamp handler
    # been wired for this widget? Set by `Widget#initialize` (for a widget
    # constructed `scrollable: true`) or by `#scrollable=` below, so the handler is
    # installed exactly once regardless of which path enables scrolling.
    @_scroll_index_wired = false

    # Enables/disables scrolling at runtime, wiring the content-clamp handler
    # (`Event::ContentParsed → reclamp_scroll_index`) a widget constructed
    # `scrollable: true` gets in `Widget#initialize`, and clamping immediately.
    # Without the handler, a content shrink would leave `@child_base` past the
    # content and the viewport blank until a manual scroll repaired it.
    def scrollable=(value : Bool) : Bool
      return value if value == @scrollable
      # Disabling freezes `@child_base` into every subsequent render while all
      # repair paths (`scroll`, `reset_scroll`, `reclamp_scroll_index`) early
      # -return on `!@scrollable` — so zero the scroll state NOW, while still
      # scrollable, letting `reset_scroll` mark dirty and emit `Event::Scroll`
      # for bound chrome/listeners itself.
      reset_scroll unless value
      @scrollable = value
      if value
        unless @_scroll_index_wired
          @_scroll_index_wired = true
          on(Crysterm::Event::ContentParsed) { reclamp_scroll_index }
        end
        reclamp_scroll_index
      end
      value
    end

    # Whether the widget position is fixed even in presence of scroll?
    # (Used by labels and the scrollbar widget, which must not scroll away.)
    property? fixed = false

    # Whether this widget is internal chrome — a border label or a bound scroll
    # bar — that an installed layout engine must *not* arrange (measure/place) as
    # a content slot. Distinct from `#layout_excluded?`: excluded chrome (a
    # `background-image` layer) is skipped by the normal child pass entirely and
    # painted out-of-band from `_render`, whereas chrome flagged here is still
    # painted by the child pass, at its own pinned coordinates (`top: -itop`,
    # `right: 0`, …) rather than as an arranged slot. Without this, any engine
    # tears a `GroupBox` title off its border row and turns a scroll bar into a
    # flex cell.
    property? layout_chrome = false

    # When a scrollable widget shows its scroll bar — Qt's `Qt::ScrollBarPolicy`.
    enum ScrollBarPolicy
      # Show the bar only while the content overflows the viewport (Qt default).
      AsNeeded
      # Always reserve and show the bar.
      AlwaysOn
      # Never show the bar.
      AlwaysOff
    end

    # When this widget's scroll bar chrome is shown (vertical only for now). Base
    # widgets default to `AlwaysOff`; scrollable widgets override to `AsNeeded`.
    property scrollbar_policy : ScrollBarPolicy = ScrollBarPolicy::AlwaysOff

    # Whether the scroll bar is enabled at all (policy not `AlwaysOff`).
    def scrollbar? : Bool
      !scrollbar_policy.always_off?
    end

    # Boolean sugar over `#scrollbar_policy`: `true` ⇒ `AsNeeded`, `false` ⇒
    # `AlwaysOff`.
    def scrollbar=(v : Bool) : Bool
      @scrollbar_policy = v ? ScrollBarPolicy::AsNeeded : ScrollBarPolicy::AlwaysOff
      v
    end

    # Qt `QAbstractScrollArea#verticalScrollBarPolicy`: alias of `#scrollbar_policy`.
    def vertical_scrollbar_policy : ScrollBarPolicy
      scrollbar_policy
    end

    # :ditto:
    def vertical_scrollbar_policy=(p : ScrollBarPolicy) : ScrollBarPolicy
      self.scrollbar_policy = p
    end

    # Qt `QAbstractScrollArea#horizontalScrollBarPolicy`. Defaults to `AlwaysOff`
    # on the base widget, so horizontal scrolling is opt-in per widget.
    property horizontal_scrollbar_policy : ScrollBarPolicy = ScrollBarPolicy::AlwaysOff

    # Thickness of the scroll bars, in cells — the **single source of truth** so
    # no part of the toolkit assumes a width of `1`. The vertical bar is
    # `#scrollbar_width` columns wide (reserved by `#content_margin_x`); the
    # horizontal bar is `#scrollbar_height` rows tall (reserved by
    # `#hscrollbar_rows`). The `ScrollBar` children are created at exactly these
    # sizes, so reserved space and rendered bar agree. Both default to `1` and may
    # be set wider; Qt's analogue is `QStyle::PM_ScrollBarExtent`.
    property scrollbar_width : Int32 = 1

    # :ditto:
    property scrollbar_height : Int32 = 1

    # Whether the scroll bar chrome should be shown now: never when non-scrollable
    # or `AlwaysOff`, always under `AlwaysOn`, on overflow under `AsNeeded`.
    def show_scrollbar? : Bool
      policy_shows?(scrollbar_policy) { overflows_y? }
    end

    # Horizontal counterpart of `#show_scrollbar?`, keyed off
    # `#horizontal_scrollbar_policy` and horizontal overflow.
    def show_horizontal_scrollbar? : Bool
      policy_shows?(horizontal_scrollbar_policy) { overflows_x? }
    end

    # Rows reserved at the bottom for a shown horizontal scroll bar, so content
    # and vertical-scroll math don't run underneath it. `0` unless the bar is
    # shown.
    def hscrollbar_rows : Int32
      show_horizontal_scrollbar? ? scrollbar_height : 0
    end

    # Content rows visible in the viewport: full height minus interior
    # (border/padding) rows minus `#hscrollbar_rows`. The single source of truth
    # for the viewport-height invariant.
    protected def visible_content_rows : Int32
      aheight - ivertical - hscrollbar_rows
    end

    # Rows the horizontal bar reserves, computed *without* consulting the vertical
    # scrollbar: the horizontal test here uses the full interior width (`awidth -
    # ihorizontal`). The vertical-overflow predicates below MUST use this variant
    # rather than `#hscrollbar_rows`, whose overflow test runs against
    # `#content_width` and would close the cycle `overflows_y? →
    # hscrollbar_rows → … → overflows_y?`.
    private def hscrollbar_rows_indep : Int32
      reserve = policy_shows?(horizontal_scrollbar_policy) do
        !wrap_content? && (scroll_width > Math.max(0, awidth - ihorizontal))
      end
      reserve ? scrollbar_height : 0
    end

    # Viewport content rows for the vertical-overflow predicates, using
    # `#hscrollbar_rows_indep` so it doesn't recurse back through the vertical
    # scrollbar. See `#hscrollbar_rows_indep`.
    private def visible_content_rows_indep : Int32
      aheight - ivertical - hscrollbar_rows_indep
    end

    # Whether a bar with *policy* should show: never when non-scrollable or
    # `AlwaysOff`, always under `AlwaysOn`, under `AsNeeded` only when the yielded
    # overflow test is true.
    private def policy_shows?(policy : ScrollBarPolicy, &) : Bool
      return false unless scrollable?
      case policy
      in .always_off? then false
      in .always_on?  then true
      in .as_needed?  then yield
      end
    end

    # The `Widget::ScrollBar` child rendering this widget's scrollbar, created
    # lazily (`nil` until first shown). Qt's `verticalScrollBar()`.
    getter scrollbar_widget : ScrollBar?

    # The horizontal `Widget::ScrollBar` child rendering this widget's horizontal
    # scrollbar, created lazily (`nil` until first shown). Qt's
    # `horizontalScrollBar()`.
    getter horizontal_scrollbar_widget : ScrollBar?

    # Reconciles the scroll bar chrome with the policy each render: create+show+
    # sync when `#show_scrollbar?`, else hide (never destroy) so it can reappear
    # without losing state. Idempotent.
    protected def update_scrollbar_widget : Nil
      # Reserve the bottom-right corner when both bars show (Qt's
      # `QAbstractScrollArea` corner): shorten the vertical bar by the horizontal
      # bar's row(s) and the horizontal bar by the vertical bar's column(s), so
      # neither box claims the corner cell. Otherwise both `"100%"` extents overlap
      # there and the second-created bar overpaints the other's last cell,
      # truncating its thumb and stealing corner clicks. The size setters are
      # change-guarded, so re-asserting this every frame is cheap. The corner is
      # left to the parent's background fill.
      if show_scrollbar?
        sb = ensure_scrollbar_widget
        sb.width = scrollbar_width
        sb.height = show_horizontal_scrollbar? ? "100%-#{scrollbar_height}" : "100%"
        sb.show
      else
        @scrollbar_widget.try &.hide
      end

      if show_horizontal_scrollbar?
        hb = ensure_horizontal_scrollbar_widget
        hb.height = scrollbar_height
        hb.width = show_scrollbar? ? "100%-#{scrollbar_width}" : "100%"
        hb.show
      else
        @horizontal_scrollbar_widget.try &.hide
      end
    end

    # Lazily create a real `Widget::ScrollBar` child pinned to the right interior
    # edge. Styleable via CSS (`ScrollBar { … }` / `.scrollbar { … }`).
    # Idempotent; returns the bar.
    protected def ensure_scrollbar_widget : ScrollBar
      sb = @scrollbar_widget ||= bind_scrollbar ScrollBar.new parent: self,
        orientation: :vertical, top: 0, right: 0, width: scrollbar_width, height: "100%"
      sb.sync_from_target
      sb
    end

    # Horizontal counterpart of `#ensure_scrollbar_widget`, pinned to the bottom
    # interior edge. Idempotent; returns the bar.
    protected def ensure_horizontal_scrollbar_widget : ScrollBar
      sb = @horizontal_scrollbar_widget ||= bind_scrollbar ScrollBar.new parent: self,
        orientation: :horizontal, left: 0, bottom: 0, height: scrollbar_height, width: "100%"
      sb.sync_from_target
      sb
    end

    # Common chrome setup for both `ensure_*` accessors: makes *sb* `fixed`,
    # `.scrollbar`-classed, and `#attach`ed so it reflects/drives the scroll
    # position. Returns *sb*.
    private def bind_scrollbar(sb : ScrollBar) : ScrollBar
      sb.fixed = true
      # Chrome: pinned to an interior edge, never arranged as a content slot by an
      # installed layout engine.
      sb.layout_chrome = true
      sb.add_css_class "scrollbar"
      sb.attach self
      sb
    end

    # --- Qt `QAbstractScrollArea` facade ------------------------------------
    # Thin Qt-shaped accessors over the scroll machinery. The widget is the
    # scroll area; its content area is the implicit `viewport()`.

    # Qt's `verticalScrollBar()`: the bound vertical `ScrollBar`, created on first
    # access (the object exists even when the policy hides it).
    def vertical_scrollbar : ScrollBar
      ensure_scrollbar_widget
    end

    # Qt's `horizontalScrollBar()`: the bound horizontal `ScrollBar`, created on
    # first access (the object exists even when the policy hides it).
    def horizontal_scrollbar : ScrollBar
      ensure_horizontal_scrollbar_widget
    end

    # Qt's `scrollContentsBy(dx, dy)`: scroll the viewport by *dy* lines
    # (vertical) and *dx* columns (horizontal).
    def scroll_contents_by(dx : Int32, dy : Int32) : Nil
      scroll dy unless dy == 0
      scroll_by_x dx unless dx == 0
    end

    # Smallest scroll base that brings *pos* inside a *visible*-cell window
    # starting at *current*, keeping *margin* cells of context, clamped into
    # `[0, extent - visible]`. Shared windowing math behind `#ensure_visible`
    # (vertical) and `#ensure_visible_x` (horizontal).
    private def windowed_base(pos : Int32, current : Int32, margin : Int32, visible : Int32, extent : Int32) : Int32
      base = current
      if pos < current + margin
        base = pos - margin
      elsif pos > current + visible - 1 - margin
        base = pos - (visible - 1) + margin
      end
      base.clamp(0, Math.max(0, extent - visible))
    end

    # Qt's `ensureVisible(y, margin)`: scroll the minimum amount so content line
    # *y* sits within the viewport, keeping *margin* lines of context. No-op when
    # already visible. Returns whether the viewport moved.
    def ensure_visible(y : Int32, margin : Int32 = 0) : Bool
      return false unless scrollable?
      visible = visible_content_rows
      return false if visible <= 0

      base = @child_base
      @child_base = windowed_base(y, @child_base, margin, visible, scroll_height)

      return false if @child_base == base
      mark_dirty
      emit Crysterm::Event::Scroll, @child_base - base
      true
    end

    # Qt's `ensureWidgetVisible(child, margin)`: scroll so descendant *child* is
    # within the viewport. Reveals the bottom edge first, then the top, so the
    # top wins when the child is taller than the viewport.
    def ensure_widget_visible(child : Widget, margin : Int32 = 0) : Bool
      # `ensure_visible` wants a content-row index in *this* container's content
      # space. `child.rtop` is relative to the child's *immediate parent*, so it
      # is only correct for a direct child; for a deeper descendant it omits the
      # intervening ancestors' offsets. Compute from absolute tops instead:
      # `child.atop - atop` is the child's row within this container, minus `itop`
      # (border/padding) gives the content-row index.
      top = (child.atop || 0) - (atop || 0) - itop
      moved = ensure_visible(top + child.aheight - 1, margin)
      ensure_visible(top, margin) || moved
    end

    # Horizontal counterpart of `#ensure_visible`: scroll so content column *x*
    # sits within the viewport. Returns whether the view moved.
    def ensure_visible_x(x : Int32, margin : Int32 = 0) : Bool
      return false unless scrollable?
      visible = content_width
      return false if visible <= 0

      base = @child_base_x
      @child_base_x = windowed_base(x, @child_base_x, margin, visible, scroll_width)

      return false if @child_base_x == base
      mark_dirty
      emit Crysterm::Event::Scroll, @child_base_x - base, Tput::Orientation::Horizontal
      true
    end

    # ------------------------------------------------------------------------

    # Should widget indicate the scroll position?
    property? track : Bool = false

    # Lines hidden above the top of content due to scrolling. 0 == no scroll;
    # 5 == 5 lines hidden, 6th line of content is first displayed.
    property child_base = 0

    # Cursor offset (in lines) within the widget. 0 == cursor at first line of
    # visible (potentially scrolled) content.
    property child_offset = 0

    # Horizontal counterparts of `child_base`/`child_offset`, in display columns.
    # `child_base_x` is the first visible column of (non-wrapped) content;
    # `child_offset_x` mirrors `child_offset` but the generic path keeps it 0, so
    # `scroll_position_x == child_base_x`. Only meaningful when `wrap_content?` is off.
    property child_base_x = 0

    # :ditto:
    property child_offset_x = 0

    property base_limit = Int32::MAX

    property? always_scroll : Bool = false

    # Qt-style sticky-bottom "follow tail": when on, the view stays pinned to the
    # bottom as content grows, but only while *already* at the bottom, so a manual
    # scroll-up is preserved. Off by default; `Widget::Log` defaults it on. *When*
    # to stick is decided by `#stick_to_tail?`.
    property? follow_tail : Bool = false

    # Bottom-most scroll offset at the previous layout. `#clamp_child_base_to_content`
    # compares `#child_base` against it to tell whether the view was at the tail
    # before the content changed.
    @last_scroll_max = 0

    # Whether to snap to the new bottom when content grows (consulted only when
    # `#follow_tail?`). Sticky-bottom by default: true only when already at the
    # tail. Subclasses may override for an always-pin mode (e.g.
    # `Widget::Log#scroll_on_input`).
    protected def stick_to_tail?(content_max : Int32) : Bool
      @child_base >= @last_scroll_max
    end

    @ev_label_scroll : Crysterm::Event::Scroll::Wrapper?

    # Potentially use this wherever .scrollable? is used
    def overflows_y?
      return @scrollable if @shrink_to_fit
      scroll_height > visible_content_rows_indep
    end

    # Whether laid-out content exceeds the visible content height (viewport minus
    # `ivertical`). Overflow test for fixed-viewport widgets (`PlainTextEdit`,
    # `List`) that scroll rather than grow — they override `#overflows_y?`
    # with this so an `AsNeeded` bar tracks real overflow instead of the
    # `@shrink_to_fit` always-scrollable short-circuit.
    def content_overflows_height?
      scroll_height > visible_content_rows_indep
    end

    # Total lines by which widget is scrolled, combining invisible and visible
    # parts. E.g. 6 lines scrolled out of window + cursor at 5th visible line
    # returns 11.
    def scroll_position : Int32
      @child_base + @child_offset
    end

    def scroll_to(offset, always = false)
      scroll 0
      scroll offset - (@child_base + @child_offset), always
    end

    def scroll_height : Int32
      Math.max @_clines.size, scroll_extent_bottom
    end

    # --- horizontal axis ----------------------------------------------------

    # Combined horizontal scroll position, in columns (mirrors `#scroll_position`).
    def scroll_position_x : Int32
      @child_base_x + @child_offset_x
    end

    # Widest content row, in display columns — horizontal analogue of
    # `#scroll_height`. Computed by `_wrap_content`; `0` for wrapped content.
    def scroll_width : Int32
      @_clines.full_width
    end

    # Columns reserved at the right of the content area beyond border/padding —
    # the vertical scroll bar's columns when shown (the bar's real
    # `#scrollbar_width`, never a hardcoded `1`). `_wrap_content` and
    # `#content_width` both subtract this, keeping them in agreement. Subclasses
    # add their own reservations (`PlainTextEdit`'s end-of-line caret column).
    def content_margin_x : Int32
      show_scrollbar? ? scrollbar_width : 0
    end

    # The right-edge reservation an *empty* (zero-line) widget would make:
    # `AlwaysOn` still reserves the bar column, `AsNeeded` reserves nothing (no
    # content ⇒ no overflow). Seeds `process_content`'s wrap-convergence pass,
    # so the first wrap of new content isn't skewed by the previous wrap's
    # line count (see `#_wrap_content`).
    def content_margin_x_empty : Int32
      policy_shows?(scrollbar_policy) { false } ? scrollbar_width : 0
    end

    # Width in columns actually available to content: the viewport minus
    # border/padding (`ihorizontal`) and the reserved right-edge columns
    # (`content_margin_x`). The horizontal analogue of the visible content
    # height, used for the horizontal scroll extent and bar range so the last
    # columns are reachable rather than hidden behind the reserved margin.
    def content_width : Int32
      Math.max 0, awidth - ihorizontal - content_margin_x
    end

    # Whether content overflows the viewport horizontally (so an `AsNeeded`
    # horizontal bar should show). Always false while wrapping, since wrapped
    # content is reflowed to fit the width.
    def overflows_x?
      return false if wrap_content?
      scroll_width > content_width
    end

    # Horizontal counterpart of `#scroll`: shift the visible column window by
    # *offset* columns, clamped to the content width, and repaint. Emits
    # `Event::Scroll` carrying the signed column delta and `:horizontal`.
    def scroll_by_x(offset = 1)
      return unless @scrollable && window?
      visible = content_width
      return if visible <= 0

      base = @child_base_x
      @child_offset_x = 0
      @child_base_x = (base + offset).clamp(0, Math.max(0, scroll_width - visible))
      return if @child_base_x == base

      mark_dirty
      emit Crysterm::Event::Scroll, @child_base_x - base, Tput::Orientation::Horizontal
    end

    # Horizontal counterpart of `#scroll_to`: move the column window so its left
    # edge sits at *offset*.
    def scroll_to_x(offset)
      scroll_by_x offset - scroll_position_x
    end

    def scroll_percent=(value : Float64) : Float64
      # Map against the same scrollable span `#scroll_percent` divides by, so
      # the two are true inverses (`w.scroll_percent = w.scroll_percent`
      # is idempotent). `scroll_percent` uses `child_base / (height_total -
      # viewport)` under `@always_scroll` and `scroll_position / (height_total - 1)`
      # otherwise; mapping set against `scroll_height` (the full content
      # height) instead over-scrolled every round-trip.
      m = @always_scroll ? scroll_height - visible_content_rows : scroll_height - 1
      scroll_to (value * Math.max(0, m)).to_i
      value
    end

    def reset_scroll
      return unless @scrollable
      prev = @child_base + @child_offset
      @child_offset = 0
      @child_base = 0
      @child_offset_x = 0
      @child_base_x = 0
      # NOTE: `@last_scroll_max` is deliberately NOT reset here. `#stick_to_tail?`
      # is `@child_base >= @last_scroll_max`; after this reset `@child_base == 0`,
      # so a stale positive `@last_scroll_max` correctly evaluates as "not at the
      # tail", leaving a `#follow_tail?` view at the top on the next content growth
      # (a reset-to-top must stay at the top, per the sticky-bottom contract).
      # Zeroing it would instead make `0 >= 0` true and snap the view to the
      # bottom.
      mark_dirty
      emit Crysterm::Event::Scroll, -prev
    end

    def scroll_percent : Float64
      # `coords` (method call), not `@coords` (a nonexistent ivar).
      pos = @lpos || coords
      return 0.0 unless pos

      height = (pos.yl - pos.yi) - ivertical - hscrollbar_rows
      i = scroll_height
      # p

      if height < i
        if @always_scroll
          @child_base / (i - height)
        else
          # `i - 1` is the scrollable span; 0 when `i <= 1` (nothing to scroll).
          # Guarded because the bare division would yield Infinity/NaN and
          # propagate garbage — 0.0 is correct there instead.
          i > 1 ? (@child_base + @child_offset) / (i - 1) : 0.0
        end
      else
        0.0
      end
    end

    protected def scroll_extent_bottom
      return 0 unless @scrollable

      # Optimization for lists: just return items.size instead of computing children.
      if @_is_list
        return @items.any? ? @items.size : 0
      end

      @lpos.try do |lpos|
        if lpos._scroll_bottom != 0
          return lpos._scroll_bottom
        end
      end

      bottom = @children.reduce(0) do |current, el|
        # `fixed` children are chrome (scroll bars, labels), not scrollable
        # content. Counting them inflated scroll height to ~viewport height,
        # keeping (e.g.) a `PlainTextEdit`'s vertical bar stuck on after its
        # content shrank back to a single line.
        next current if el.fixed?

        # `el.aheight` alone doesn't reflect shrunken height; a shrunken box
        # inside a scrollable element won't grow past the scrollable element's
        # context regardless of its content, unless we call get_coords without
        # the scrollable calculation. See: test/widget-shrink-fail-2
        el_bottom = if el.window? && (lpos = el.coords(false, true, into: (@_scrollb_lpos ||= RenderedGeometry.new)))
                      el.rtop + (lpos.yl - lpos.yi)
                    else
                      el.rtop + el.aheight
                    end
        Math.max current, el_bottom
      end

      # XXX Use this? Makes .scroll_height useless
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
      return unless window?

      # A scroll shifts the whole viewport, so the subtree must be repainted.
      mark_dirty

      # visible == content lines actually visible (e.g. height=4 with border ==
      # 2 visible lines). A shown horizontal bar reserves the bottom row.
      visible = visible_content_rows
      return if visible <= 0
      # Index of the first content line actually shown (base == 2 means content
      # shows from its 3rd line onward).
      base = @child_base
      # Combined position before the move, so `Event::Scroll` can report the
      # signed delta (`scroll_position` shifts by both base and offset changes).
      before = @child_base + @child_offset

      if @always_scroll || always
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

      if @child_base == base
        return emit Crysterm::Event::Scroll, (@child_base + @child_offset) - before
      end

      # Handles SGR codes and line feeds, so preformatted text from other
      # programs can be put in a scrollable text box.
      process_content

      clamp_child_base_to_content

      # Optimize scrolling with CSR + IL/DL.
      p = @lpos
      if p && (@child_base != base) && window.sides_uniform?(self)
        t = p.yi + itop
        b = p.yl - ibottom - 1
        d = @child_base - base

        # The CSR path mutates window buffer rows `t..b` directly
        # (`shift_lines` delete_at/insert), so both bounds must lie inside the
        # buffer. `sides_uniform?`'s full-width shortcut returns true WITHOUT the
        # vertical bounds check its fast-csr branch does, so a full-width
        # scrollable extending past the screen edge (top: 3, height: "100%" →
        # b > aheight-1; top: -3 → t < 0) reached here unclamped: a too-large
        # `b` raised IndexError mid-mutation leaving `@lines` short, and a
        # negative `t` wrapped `delete_at` around to evict BOTTOM rows,
        # desyncing `@lines`/`@flushed_lines` from the terminal. Off-screen rows can't
        # be CSR-scrolled anyway; fall through to a normal repaint instead.
        if t >= 0 && b <= window.aheight - 1
          if d > 0 && d < visible
            # scrolled down
            window.delete_line(d, t, t, b)
          elsif d < 0 && -d < visible
            # scrolled up
            d = -d
            window.insert_line(d, t, t, b)
          end
        end
      end

      emit Crysterm::Event::Scroll, (@child_base + @child_offset) - before
    end

    # Clamps `@child_base` into the valid `[0, @base_limit]` range. Kept as an
    # explicit branch (rather than `.clamp`) so it never raises even if
    # `@base_limit` is set below 0.
    private def clamp_child_base
      if @child_base < 0
        @child_base = 0
      elsif @child_base > @base_limit
        @child_base = @base_limit
      end
    end

    # Pulls `@child_base` down to the largest valid scroll offset for the current
    # content — the greater of the wrapped-content height (`@_clines.size`) and
    # the descendant extent (`scroll_extent_bottom`), each measured against the visible
    # inner height — then re-clamps into `[0, @base_limit]`. Shared by `#scroll`
    # and `#reclamp_scroll_index`.
    private def clamp_child_base_to_content
      visible = visible_content_rows

      # With no visible content rows there is nothing to scroll to, so the base
      # must clamp to 0; `size - visible`/`scroll_extent_bottom - visible` would
      # otherwise degrade to the full content height and fail to rein in a bad
      # base.
      if visible <= 0
        content_max = 0
      else
        max = @_clines.size - visible
        max = 0 if max < 0
        emax = scroll_extent_bottom - visible
        emax = 0 if emax < 0
        content_max = Math.max emax, max
      end

      # Qt sticky-bottom (`#follow_tail`): when following the tail and the view
      # was already at the bottom (or pinned — see `#stick_to_tail?`), snap to the
      # new bottom as content grows; otherwise only pull the base *down* into
      # range, so a reader who scrolled up is never yanked down. With follow-tail
      # off this reduces to `min(child_base, content_max)`.
      if follow_tail? && stick_to_tail?(content_max)
        @child_base = content_max
      else
        @child_base = Math.min @child_base, content_max
      end
      @last_scroll_max = content_max

      clamp_child_base
    end

    protected def reclamp_scroll_index
      return 0 if !window? || !@scrollable

      clamp_child_base_to_content
    end
  end
end
