module Crysterm
  class Screen
    # Widget focus.
    #
    # Broader in scope than mouse focus, since widget focus can be affected
    # by keys (Tab/Shift+Tab etc.) and operate without mouse.

    # Send focus events after mouse is enabled?
    property send_focus : Bool = Config.screen_send_focus

    # Whether `Tab`/`Shift+Tab` move keyboard focus between focusable widgets by
    # default (the GUI-toolkit convention). Enabled out of the box; set to false
    # to take full control of `Tab` handling yourself.
    #
    # This default only kicks in for keys that the focused widget (and its parent
    # chain, e.g. an enclosing `Widget::Form`) did not already handle, so it
    # composes with widgets that do their own `Tab` navigation.
    property? tab_navigation : Bool = Config.screen_tab_navigation

    property _saved_focus : Widget?

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
      @_saved_focus = focused
    end

    # Restores focus to the previously saved focused element.
    def restore_focus
      return unless sf = @_saved_focus
      @_saved_focus = nil
      # The saved widget may have been detached/removed (or moved to another
      # screen) while focus was held elsewhere — e.g. a dialog that saved the
      # previously-focused widget (see `Widget::Message`/`Question`/`Prompt`/
      # `FileManager`/`ColorDialog`) outlives the widget it saved. `Widget#focus`
      # would then dereference that widget's now-nil `screen` (`screen?.not_nil!`)
      # and crash. Restore focus only when the saved widget is still attached to
      # THIS screen; otherwise there is no valid prior target (and focusing it on
      # another screen would be wrong anyway). Mirrors the `screen?`/attachment
      # guards already used by `rewind_focus` and `focus_offset`.
      sf.focus if sf.screen? == self
      focused
    end

    # "Rewinds" focus to the most recent visible and attached element.
    #
    # As a side-effect, prunes the focus history list.
    def rewind_focus
      # `pop?` (not `pop`) so a re-entrant or otherwise empty-history call
      # degrades to a no-op instead of raising IndexError.
      old = @history.pop?

      # `reverse_each` walks the history back-to-front in place; the old
      # `@history.reverse.find` allocated a whole reversed copy of the array
      # just to scan it once.
      el = nil
      @history.reverse_each do |e|
        # `screen? == self` (not the raising `screen`, nor a bare truthy
        # `screen?`): a widget that was destroyed/detached while in the history has
        # no screen, and the raising `#screen` would crash here (e.g. closing a
        # menu whose submenu — the focused widget — was just torn down). A bare
        # `screen?` would skip only the detached case but still accept a widget
        # MOVED to another screen (its `@keyable`/history entries are not pruned —
        # see `focus_offset`/`screen_children.cr#remove`), re-focusing a widget that
        # now lives on a different screen. Require attachment to THIS screen, as
        # `restore_focus` already does.
        #
        # `displayed_in_tree?` (not the per-widget `style.visible?`): a widget
        # whose own flag is visible but whose container is hidden is not actually
        # on screen, so it must not be re-focused. See the same helper in
        # `screen_mouse.cr`.
        if e.screen? == self && displayed_in_tree?(e)
          el = e
          break
        end
      end
      @history.clear

      unless el
        # No valid prior target remains (e.g. the focused widget — or its whole
        # subtree — was hidden or removed, and nothing earlier in the history is
        # still attached and visible). Focus is now cleared: `@history` is empty,
        # so `focused` already returns nil. But `old` (the widget we just popped)
        # must still be *blurred* — drop its `:focused` state and emit `Event::Blur`
        # — exactly as `_focus` does on a normal transition. Without this the
        # detached/hidden widget lingers in `WidgetState::Focused` (e.g. it would
        # reappear visually focused on `#show`) and no listener ever sees focus
        # leave it. `nil` payload: there is no widget taking over focus.
        old.try do |o|
          o.state = :normal
          o.emit Crysterm::Event::Blur, nil
        end
        return
      end

      # `_focus` (below) already emits `Event::Blur` on `old` (with the
      # newly-focused widget as payload), exactly as `focus_push`/`focus_pop` rely
      # on. Emitting it here too produced a *double* Blur on `old` — a stale, now
      # redundant leftover from before focus changes were centralized in `_focus`.
      @history.push el
      _focus el, old
      el
    end

    # Focuses element `el`. Equivalent to `@display.focused = el`.
    def focus_push(el)
      old = @history.last?
      @history.shift if @history.size >= Config.focus_history_size
      @history.push el
      _focus el, old
    end

    # Removes focus from the current element and focuses the element that was previously in focus.
    def focus_pop
      old = @history.pop
      if el = @history.last?
        _focus el, old
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
    def focus_offset(offset)
      return if offset.zero?

      # We only need to know whether *any* keyable element is visible, so
      # `any?` (which short-circuits on the first match) is enough; the old
      # `count { ... }.zero?` always scanned the entire list.
      #
      # `screen? == self` (not the raising `screen`, nor a bare truthy `screen?`):
      # `@keyable` is NOT pruned when a widget is removed (the pruning in
      # `screen_children.cr#remove` is still disabled — see its `XXX`), so it can
      # hold widgets that were detached (whose `@screen` is now nil) OR moved to
      # another screen (whose `screen?` now points elsewhere). `screen`
      # (`screen?.not_nil!`) would crash on a detached entry; a bare `screen?`
      # would skip the detached case but still select a widget that now lives on a
      # DIFFERENT screen — Tab here would then focus a widget on another screen.
      # Require attachment to THIS screen, matching `restore_focus`/`rewind_focus`.
      #
      # `displayed_in_tree?` (not the per-widget `style.visible?`) so a candidate
      # sitting inside a hidden container is skipped, not selected — its own flag
      # may still be visible. Mirrors `rewind_focus` and the mouse hit-test.
      #
      # `!el.disabled?`: a disabled widget does not react to keys (see
      # `_listen_keys`), so Tab/Shift+Tab must step over it rather than strand
      # focus on a dead widget — the GUI-toolkit convention (Qt skips disabled
      # widgets in the focus chain). Worse, landing on it would route through
      # `_focus`, which sets `state = :focused` and thereby silently clears the
      # `Disabled` state. Folding the check in here (and into the skip loop below)
      # also keeps the loop's termination guarantee intact: the `any?` proves at
      # least one acceptable candidate exists.
      return unless @keyable.any? { |el| el.screen? == self && displayed_in_tree?(el) && !el.disabled? }

      # With no current focus, enter from the natural end: forward navigation
      # (`focus_next`) must land on the FIRST focusable widget, backward
      # (`focus_previous`) on the LAST. A single `-1` sentinel only gets the
      # forward case right (`-1 + 1 == 0`); for a negative offset `-1 + -1`
      # wraps to second-from-last (or, with two widgets, the first) — never the
      # last. So when `focused` isn't in the list, pick the virtual start per
      # direction: just-before-0 going forward, 0 going backward (so the first
      # backward step is `-1`, which wraps to the last element).
      i = if idx = @keyable.index(focused)
            idx + offset
          elsif offset > 0
            offset - 1
          else
            offset
          end

      i %= @keyable.size
      while @keyable[i].screen? != self || !displayed_in_tree?(@keyable[i]) || @keyable[i].disabled?
        i += offset >= 0 ? 1 : -1
        i %= @keyable.size
      end

      focus @keyable[i]
    end

    def _focus(cur : Widget, old : Widget? = nil)
      # Re-focusing the already-focused widget has no "previous" to blur or
      # un-highlight: treating `cur` as its own `old` would set its state to
      # `:focused` (a no-op) and then immediately back to `:normal` (clobbering
      # the highlight), plus emit a spurious `Blur` on the widget being focused.
      # This is reachable via the public `Screen#focus`/`focus_offset` (e.g. Tab
      # with a single focusable widget wraps back onto it); `Widget#focus` already
      # guards it, but the screen-level entry points do not.
      #
      # It is also not a focus *change*: focus does not move, so the terminating
      # `Event::Focus` below is suppressed too. Emitting it would re-run all of the
      # widget's focus side effects on a widget that was *already* focused — a
      # `Widget::Terminal` re-reporting focus-in (`\e[I`) to its child PTY, a
      # `text_editing` widget with `input_on_focus` re-entering `read_input`,
      # `action_bar`/`menu_bar`/`completer`/remote DOM focus handlers re-firing —
      # the very same spurious-Focus defect `screen_rendering.cr#_render` already
      # guards against per frame. `Event::Focus` denotes a focus change and must
      # fire only when focus actually moves.
      refocus = old == cur
      old = nil if refocus

      # Find a scrollable ancestor if we have one.
      el = cur
      while el = el.parent
        if el.scrollable?
          break
        end
      end

      # TODO is it valid that this isn't Widget?
      # unless el.is_a? Widget
      #  raise "Unexpected"
      # end

      # TODO temporary
      cur.try &.state = :focused
      old.try &.state = :normal

      # If we're in a scrollable element,
      # automatically scroll to the focused element.
      if el && el.screen
        # Note: This is different from the other "visible" values - it needs the
        # visible height of the scrolling element itself, not the element within it.
        # NOTE why a/i values can be nil?
        visible = cur.screen.aheight - (el.atop || 0) - (el.itop || 0) - (el.abottom || 0) - (el.ibottom || 0)
        if cur.rtop < el.child_base
          # XXX remove 'if' when Screen is no longer parent of elements
          if el.is_a? Widget
            el.scroll_to cur.rtop
          end
          cur.screen.render
        elsif (cur.rtop + cur.aheight - cur.ibottom) > (el.child_base + visible)
          # Explanation for el.itop here: takes into account scrollable elements
          # with borders otherwise the element gets covered by the bottom border:
          # XXX remove 'if' when Screen is no longer parent of elements (Now it's not
          # so removing. Eventually remove this note altogether.)
          # if el.is_a? Widget
          el.scroll_to cur.rtop - (el.aheight - cur.aheight) + el.itop, true
          # end
          cur.screen.render
        end
      end

      if old
        old.emit Crysterm::Event::Blur, cur
      end

      # Per-widget cursor: if the newly-focused or the blurred widget carries its
      # own cursor, re-apply the now-active cursor so the override (or the screen
      # default it falls back to) takes effect. Skipped entirely when neither
      # widget uses the feature, so apps that don't override the cursor see no
      # change in behavior.
      if cur.cursor || old.try(&.cursor)
        apply_cursor
        # If the blurred widget was drawing an artificial cursor, repaint so its
        # cell is erased now that a different cursor is active.
        render_if_active if old.try(&.cursor).try(&.artificial?)
      end

      cur.emit Crysterm::Event::Focus, old unless refocus
    end
  end
end
