module Crysterm
  class Window
    # Chrome-region focus cycling.
    #
    # The window's chrome bars (`MenuBar`, `ToolBar`, an interactive
    # `StatusBar` — any widget with `Widget#region_focusable?`) are deliberately
    # not on the Tab chain (their focus policy is `Click`). They are reached by
    # keyboard through the *region cycle* instead, the F6/Shift+F6 convention of
    # desktop apps: each press moves focus to the next chrome region in visual
    # order, with the central area (whatever ordinary widget was focused) as the
    # ring's last stop, and Escape returns from any region straight to the
    # central area. The `MenuBar` additionally has its own dedicated activation
    # key (`MenuBar#activation_key`, F10 by default) built on the same
    # enter/return primitives.

    # Whether `F6`/`Shift+F6` cycle keyboard focus between chrome regions
    # (see above), and `Escape` returns focus from a region to the central
    # area. Enabled out of the box; set to false to take full control of those
    # keys yourself. Like `#tab_navigation`, only kicks in for keys the focused
    # widget (and its parent chain) didn't already handle.
    property? region_navigation : Bool = Config.window_region_navigation

    # The central-area widget focus returns to when the region cycle leaves
    # chrome again (`#focus_central`). Recorded by `#focus_region` when focus
    # moves from the central area into a region; consumed by the restore.
    @region_return_focus : Widget?

    # Moves focus to the next stop of the region ring: the participating chrome
    # regions in visual order, then the central area.
    def focus_region_next
      focus_region_offset 1
    end

    # Moves focus to the previous stop of the region ring.
    def focus_region_previous
      focus_region_offset -1
    end

    # Focuses chrome region *bar* (its `#region_target`), first remembering the
    # currently focused central-area widget so `#focus_central` can return to
    # it. A no-op when *bar* resolves to no focus target (e.g. a `StatusBar`
    # with nothing focusable in it).
    def focus_region(bar : Widget) : Nil
      target = region_target(bar) || return
      remember_central_focus
      focus target
    end

    # Returns focus from chrome to the central area: the widget remembered by
    # `#focus_region` when it is still a valid target, else — with focus still
    # stranded on a chrome region — the first Tab-focusable widget outside any
    # region. A no-op when neither exists.
    def focus_central : Nil
      rf = @region_return_focus
      @region_return_focus = nil
      if rf && focusable_here?(rf) && !region_of(rf)
        focus rf
      elsif region_of(focused) && (t = first_central_target)
        focus t
      end
    end

    # Focuses a region ring stop *offset* away from the current one. The ring
    # is `collect_regions` + one virtual stop for the central area; with focus
    # not in any region, the walk starts from the central stop.
    protected def focus_region_offset(offset : Int32) : Nil
      return if offset.zero?
      regions = collect_regions
      return if regions.empty?

      size = regions.size + 1 # + the central area
      cur = region_of(focused)
      i = if cur && (idx = regions.index(cur))
            idx + offset
          else
            # The central area is the ring's last stop, index `regions.size`.
            regions.size + offset
          end
      i = ((i % size) + size) % size

      if i == regions.size
        focus_central
      else
        remember_central_focus unless cur
        region_target(regions[i]).try { |t| focus t }
      end
    end

    # The chrome region *el* sits in — its closest self-or-ancestor with
    # `Widget#region_focusable?` — or `nil` for a central-area widget. (An open
    # pop-up menu is a *window* child, not a bar descendant, so it counts as
    # central here; that is fine — menus manage their own focus hand-back.)
    protected def region_of(el : Widget?) : Widget?
      while el
        return el if el.region_focusable?
        el = el.parent
      end
      nil
    end

    # The participating chrome regions, in visual order (top-to-bottom, then
    # left-to-right, by painted position): every `region_focusable?` widget on
    # screen that resolves to a focus target. Collected per keypress — region
    # sets are tiny (a menu bar, a few tool bars) and this keeps the ring
    # honest against bars being hidden/added/moved with no registry to sync.
    private def collect_regions : Array(Widget)
      regions = [] of Widget
      children.each do |c|
        c.self_and_each_descendant do |w|
          regions << w if w.region_focusable? && focusable_here?(w) && region_target(w)
        end
      end
      regions.sort_by! do |w|
        r = w.painted_rect
        {r[1], r[0]}
      end
    end

    # The widget focus actually lands on when entering region *bar*: the bar
    # itself when it takes keys (`MenuBar`/`ToolBar`), else its first keyable
    # descendant (how a `StatusBar` becomes reachable once it hosts something
    # interactive), else `nil` — a target-less region is skipped entirely.
    private def region_target(bar : Widget) : Widget?
      return bar if bar.keyable? && focusable_here?(bar)
      target = nil
      bar.each_descendant do |w|
        target ||= w if w.keyable? && focusable_here?(w)
      end
      target
    end

    # Records the focused widget as the `#focus_central` return target — only
    # when focus actually is in the central area (entering chrome from chrome
    # must not clobber the memory with a bar).
    private def remember_central_focus : Nil
      f = focused
      @region_return_focus = f if f && !region_of(f)
    end

    # The first Tab-focusable widget outside any chrome region — the
    # `#focus_central` fallback when no return target was remembered.
    private def first_central_target : Widget?
      @keyable.find { |el| tab_target?(el) && !region_of(el) }
    end
  end
end
