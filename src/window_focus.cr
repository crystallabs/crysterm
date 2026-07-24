module Crysterm
  class Window
    # Widget focus.
    #
    # Broader in scope than mouse focus, since widget focus can be affected
    # by keys (Tab/Shift+Tab etc.) and operate without mouse.

    # Whether the terminal reports focus-in/out (DEC private mode 1004) while
    # mouse reporting is on. Reports surface as window-level `Event::Mouse`
    # events whose `#mouse.focus_event?` is true (`Action::Focus`/`::Blur`).
    # Applied whenever mouse reporting is (re-)asserted; setting it while the
    # mouse is already live re-asserts immediately.
    getter? send_focus : Bool = Config.window_send_focus

    # :ditto:
    def send_focus=(value : Bool)
      return if @send_focus == value
      @send_focus = value
      @screen.enable_mouse(focus: value) if @screen.mouse_enabled?
    end

    # Whether `Tab`/`Shift+Tab` move keyboard focus between focusable widgets by
    # default (the GUI-toolkit convention). Enabled out of the box; set to false
    # to take full control of `Tab` handling yourself.
    #
    # Only kicks in for keys the focused widget (and its parent chain, e.g. an
    # enclosing `Widget::Form`) didn't already handle, so it composes with
    # widgets that do their own `Tab` navigation.
    property? tab_navigation : Bool = Config.window_tab_navigation

    # The widget stashed by `#save_focus`, or `nil` when nothing is stashed.
    # Read-only: `#save_focus`/`#restore_focus`/`#clear_saved_focus` own the slot.
    getter saved_focus : Widget?

    @history = [] of Widget
    @clickable = [] of Widget
    @keyable = [] of Widget

    # Returns the current/top element from the focus history list.
    def focused : Widget?
      @history[-1]?
    end

    # Makes `el` become the current/top element in the focus history list.
    def focus(el)
      focus_push el
    end

    # Focuses previous element in the list of focusable elements.
    def focus_previous
      focus_offset -1
    end

    # Focuses next element in the list of focusable elements.
    def focus_next
      focus_offset 1
    end

    # Saves/remembers the currently focused element.
    def save_focus
      @saved_focus = focused
    end

    # Whether `el` is attached to THIS screen and actually on screen (not hidden
    # nor inside a hidden container, and not layout-suppressed). This is the
    # trailing-history prune predicate that `rewind_focus`/`focus_pop` share; it
    # deliberately omits any `disabled?` term.
    private def on_screen_here?(el)
      el.window? == self && displayed_in_tree?(el) && !el.layout_suppressed?
    end

    # Whether `el` is a valid focus target on this screen right now: on screen
    # (`#on_screen_here?`) *and* not disabled.
    private def focusable_here?(el)
      on_screen_here?(el) && !el.disabled?
    end

    # Restores focus to the previously saved focused element.
    def restore_focus
      return unless sf = @saved_focus
      @saved_focus = nil
      # A dialog can outlive the widget it saved, so by now the saved widget may
      # have been detached, moved to another screen, hidden (switched tab page,
      # hidden parent) or disabled. `Widget#focus` guards none of that: it would
      # dereference a nil `screen` and crash, focus an off-screen widget, or —
      # `WidgetState` being single-valued — clobber `Disabled` back to keyable
      # and hand a disabled widget keys. With no valid target, leave focus as-is.
      sf.focus if focusable_here?(sf)
      focused
    end

    # Discards the saved-focus slot without restoring it, so a finished
    # focus-owning interaction can't have its stale save replayed by an
    # unrelated later `#restore_focus`.
    def clear_saved_focus
      @saved_focus = nil
    end

    # "Rewinds" focus to the most recent visible and attached element.
    #
    # As a side-effect, prunes the focus history list.
    def rewind_focus
      # `pop?` (not `pop`) so a re-entrant or otherwise empty-history call
      # degrades to a no-op instead of raising IndexError.
      old = @history.pop?

      # Prune only the invalid *trailing* entries, popping back-to-front until
      # the top is a still-valid target (or the history empties). Clearing the
      # whole history would discard older-but-still-valid entries, so a second
      # `rewind_focus` (Tab A→B→C, hide C rewinds to B, then hide B) would blur
      # focus entirely instead of falling back to the still-visible A.
      #
      # Per-entry validity: `window? == self`, not the raising `screen` (a
      # destroyed/detached widget has none) nor a bare truthy `window?` (which
      # accepts a widget moved to another screen; `@history` entries are never
      # pruned). `displayed_in_tree?`, not `style.visible?`, so a widget whose
      # own flag is visible inside a hidden container is not re-focused.
      while (e = @history.last?) && !on_screen_here?(e)
        @history.pop
      end
      el = @history.last?

      unless el
        # No valid prior target remains, so `focused` already returns nil — but
        # the just-popped `old` must still be *blurred*, or the detached/hidden
        # widget lingers in `WidgetState::Focused` (reappearing visually focused
        # on `#show`) with no listener ever seeing focus leave it. `nil` payload:
        # no widget is taking over focus.
        old.try do |o|
          o.emit Crysterm::Event::FocusOut, nil if blur_state_reset o
        end
        return
      end

      # `el` is already on top of `@history` (the surviving entry after the
      # trailing tail was pruned), so it must NOT be pushed again. `_focus`
      # already emits `Event::FocusOut` on `old`; emitting it here too would
      # double-fire FocusOut.
      _focus el, old
      el
    end

    # Focuses element `el`. Equivalent to `@display.focused = el`.
    protected def focus_push(el)
      old = @history.last?
      # Re-focusing the already-current element is not a history change. Pushing
      # it again would stack a duplicate top entry and, once `@history` reaches
      # `focus_history_size`, rotate a legitimately older entry off the front,
      # corrupting the `focus_pop`/`rewind_focus` back-stack walk. Screen-level
      # entry points reach here with `old == el` readily (Tab with a single
      # focusable widget). `_focus` already treats it as a full no-op.
      if old == el
        _focus el, old
        return
      end
      @history.shift if @history.size >= Config.focus_history_size
      @history.push el
      _focus el, old
    end

    # Removes focus from the current element and focuses the element that was previously in focus.
    def focus_pop
      # Non-raising pop: `focus_pop` is public API and the history may be empty.
      old = @history.pop?

      # Prune invalid *trailing* entries before restoring focus. `@history` is
      # never pruned on widget removal, so the new top may be a detached/hidden
      # widget: `_focus`ing it would set `state = :focused` on an off-window
      # widget, route keys off-screen, and — if it has a scrollable ancestor —
      # crash in the scroll-into-view guard (`el.window` = `window?.not_nil!`).
      # Same predicate as `rewind_focus` so a valid older entry still survives.
      while (e = @history.last?) && !on_screen_here?(e)
        @history.pop
      end

      if el = @history.last?
        _focus el, old
      elsif old
        # No prior target remains, but the just-popped widget must still be
        # blurred, or it lingers in `WidgetState::Focused` with no listener
        # seeing focus leave it.
        old.emit Crysterm::Event::FocusOut, nil if blur_state_reset old
      end
      old
    end

    # Focuses an element by an offset in the list of focusable elements.
    #
    # E.g. `focus_offset 1` moves focus to the next focusable element.
    # `focus_offset 3` moves focus 3 focusable elements further.
    #
    # If the end of list of focusable elements is reached before the
    # item to focus is found, the search continues from the beginning.
    protected def focus_offset(offset)
      return if offset.zero?

      # The skip loop below only terminates because this proves an acceptable
      # candidate exists, so it must use the very same predicate.
      return unless @keyable.any? { |el| tab_target?(el) }

      # With no current focus, enter from the natural end: forward navigation
      # lands on the FIRST focusable widget, backward on the LAST. Hence a
      # virtual start per direction — just-before-0 forward, 0 backward (so the
      # first backward step is `-1`, wrapping to the last). A single `-1`
      # sentinel would only get the forward case right.
      i = if idx = @keyable.index(focused)
            idx + offset
          elsif offset > 0
            offset - 1
          else
            offset
          end

      i %= @keyable.size
      while !tab_target?(@keyable[i])
        i += offset >= 0 ? 1 : -1
        i %= @keyable.size
      end

      focus @keyable[i]
    end

    # Whether Tab navigation may land on *el* right now: a valid focus target
    # (`focusable_here?`) whose focus policy accepts Tab — a `Click`-policy
    # widget stays mouse-focusable but is stepped over. Only Tab traversal uses
    # this narrower predicate; click-focus and `restore_focus` keep
    # `focusable_here?`.
    private def tab_target?(el) : Bool
      focusable_here?(el) && el.accepts_tab_focus?
    end

    # Clears a blurred widget's transient `:focused` state — but only when it is
    # actually Focused — returning whether it reset. `WidgetState` is
    # single-valued, so an unconditional `state = :normal` would re-enable a
    # widget disabled *while focused* and clobber a Selected/Hovered state a
    # blurred widget may legitimately hold.
    @[AlwaysInline]
    private def blur_state_reset(o : Widget) : Bool
      return false unless o.state.focused?
      o.state = :normal
      true
    end

    protected def _focus(cur : Widget, old : Widget? = nil)
      # Re-focusing the already-focused widget has no "previous" to blur or
      # un-highlight: treating `cur` as its own `old` would set its state to
      # `:focused` then immediately back to `:normal` (clobbering the
      # highlight), plus emit a spurious `FocusOut`. It's also not a focus *change*,
      # so the terminating `Event::FocusIn` is suppressed too — emitting it would
      # re-run focus side effects on an already-focused widget (a `Terminal`
      # re-reporting focus-in to its PTY, `input_on_focus` re-entering
      # `read_input`, menu/completer handlers re-firing).
      refocus = old == cur
      old = nil if refocus

      # Find a scrollable ancestor if we have one (starting *above* cur — a
      # focused scrollable widget doesn't scroll itself to reveal itself).
      el = cur.parent.try &.first_self_or_ancestor &.scrollable?

      cur.state = :focused
      old.try { |o| blur_state_reset o }

      # If we're in a scrollable element, automatically scroll the focused
      # element into view. `#ensure_widget_visible` maps the descendant's row
      # into `el`'s content space via absolute tops; hand-rolled `cur.rtop` math
      # would be relative to `cur`'s *immediate* parent, so it omits the
      # intervening offsets for anything deeper than a direct child.
      if el && (elw = el.window?)
        elw.render if el.ensure_widget_visible cur
      end

      if old
        old.emit Crysterm::Event::FocusOut, cur
      end

      # Per-widget cursor: if the newly-focused or blurred widget carries its own
      # cursor, re-apply the now-active cursor so the override (or the screen
      # default) takes effect. Skipped when neither widget uses the feature.
      if cur.cursor || old.try(&.cursor)
        apply_cursor
        # If the blurred widget was drawing an artificial cursor, repaint so its
        # cell is erased now that a different cursor is active.
        render_if_active if old.try(&.cursor).try(&.artificial?)
      end

      cur.emit Crysterm::Event::FocusIn, old unless refocus
    end
  end
end
