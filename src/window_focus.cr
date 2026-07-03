module Crysterm
  class Window
    # Widget focus.
    #
    # Broader in scope than mouse focus, since widget focus can be affected
    # by keys (Tab/Shift+Tab etc.) and operate without mouse.

    # Send focus events after mouse is enabled?
    property send_focus : Bool = Config.window_send_focus

    # Whether `Tab`/`Shift+Tab` move keyboard focus between focusable widgets by
    # default (the GUI-toolkit convention). Enabled out of the box; set to false
    # to take full control of `Tab` handling yourself.
    #
    # Only kicks in for keys the focused widget (and its parent chain, e.g. an
    # enclosing `Widget::Form`) didn't already handle, so it composes with
    # widgets that do their own `Tab` navigation.
    property? tab_navigation : Bool = Config.window_tab_navigation

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
      # would then dereference that widget's now-nil `screen` (`window?.not_nil!`)
      # and crash. Restore focus only when still attached to THIS screen; mirrors
      # the `window?`/attachment guards in `rewind_focus`/`focus_offset`.
      #
      # `displayed_in_tree?` (not `style.visible?`): while the dialog was open,
      # the saved widget or a container above it may have been hidden (switched
      # tab page, hidden parent) — attached but off-screen. `Widget#focus` does
      # not itself gate on visibility, so without this it would focus an
      # invisible widget and emit `Event::Focus`. If no valid target remains,
      # leave focus as-is, as the other two focus paths do for a hidden candidate.
      #
      # `!sf.disabled?`: the saved widget may have been disabled while the dialog
      # was open (a wizard disabling a field). `WidgetState` is single-valued and
      # `_focus` sets `state = :focused`, so re-focusing a disabled widget would
      # silently clobber `Disabled` back to keyable and hand it keys the app
      # disabled — every other focus entry point (`focus_offset`) already guards
      # on this (BUGS-F2 #26).
      sf.focus if sf.window? == self && displayed_in_tree?(sf) && !sf.disabled?
      focused
    end

    # Discards the saved-focus slot without restoring it. Used by callers that
    # finish a focus-owning interaction (e.g. a reading text field that ended
    # while still focused, or after focus deliberately moved elsewhere) so the
    # stale save can't be replayed by an unrelated later `#restore_focus`.
    def clear_saved_focus
      @_saved_focus = nil
    end

    # "Rewinds" focus to the most recent visible and attached element.
    #
    # As a side-effect, prunes the focus history list.
    def rewind_focus
      # `pop?` (not `pop`) so a re-entrant or otherwise empty-history call
      # degrades to a no-op instead of raising IndexError.
      old = @history.pop?

      # Prune only the invalid *trailing* entries, popping back-to-front until
      # the top is a still-valid target (or the history empties). Blessed's
      # `rewindFocus` prunes just this tail; the old `@history.clear` here
      # discarded ALL older-but-still-valid entries too, so a second
      # `rewind_focus` (e.g. Tab A→B→C, hide C rewinds to B, then hide B) found
      # nothing to fall back to and blurred focus entirely, even though an older
      # valid entry (A) was still visible and should have been refocused.
      #
      # Per-entry validity, same predicate as before:
      #
      # `window? == self` (not the raising `screen`, nor a bare truthy
      # `window?`): a destroyed/detached widget has no screen, and `#screen`
      # would crash here (e.g. closing a menu whose focused submenu was just
      # torn down). A bare `window?` would still accept a widget MOVED to
      # another screen — and `@history` entries (unlike `@keyable`, now pruned
      # on remove via `Window#unregister`) are never pruned at all. Require
      # attachment to THIS screen, as `restore_focus` does.
      #
      # `displayed_in_tree?` (not `style.visible?`): a widget whose own flag
      # is visible but whose container is hidden isn't actually on screen and
      # must not be re-focused. See the same helper in `window_mouse.cr`.
      while (e = @history.last?) && !(e.window? == self && displayed_in_tree?(e))
        @history.pop
      end
      el = @history.last?

      unless el
        # No valid prior target remains. Focus is now cleared (`@history` is
        # empty, so `focused` already returns nil), but `old` (just popped) must
        # still be *blurred* — drop its `:focused` state and emit `Event::Blur`,
        # as `_focus` does on a normal transition. Otherwise the detached/hidden
        # widget lingers in `WidgetState::Focused` (e.g. reappears visually
        # focused on `#show`) with no listener ever seeing focus leave it. `nil`
        # payload: no widget is taking over focus.
        # Mirror `_focus`'s guard: only blur-reset a widget that is actually
        # Focused. `WidgetState` is single-valued, so an unconditional
        # `state = :normal` re-enables a widget disabled while focused and
        # clobbers a Selected/Hovered state — and would emit `Blur` for a widget
        # that wasn't focused (BUGS-F2 #27).
        old.try do |o|
          if o.state.focused?
            o.state = :normal
            o.emit Crysterm::Event::Blur, nil
          end
        end
        return
      end

      # `el` is already on top of `@history` (the surviving valid entry after
      # the trailing tail was pruned), so it must NOT be pushed again — doing so
      # would stack a duplicate top entry. `_focus` (below) already emits
      # `Event::Blur` on `old`, as `focus_push`/`focus_pop` rely on; emitting it
      # here too would double-Blur `old`.
      _focus el, old
      el
    end

    # Focuses element `el`. Equivalent to `@display.focused = el`.
    def focus_push(el)
      old = @history.last?
      # Re-focusing the already-current element is not a history change.
      # Pushing it again would stack a duplicate top entry and, once `@history`
      # reaches `focus_history_size`, rotate a legitimately older entry off the
      # front, corrupting the `focus_pop`/`rewind_focus` back-stack walk (a
      # later `focus_pop` would pop the duplicate instead of returning to the
      # real prior widget). Screen-level entry points reach here with
      # `old == el` readily: `focus_offset`/Tab resolves back onto the focused
      # widget when it's the sole focusable one, and `Window#focus` has no
      # `Widget#focus`-style `focused?` guard. `_focus` already treats
      # `old == el` as a full no-op (see `focus_refocus_emission_spec`), so
      # re-run that and leave the history untouched.
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
      # Non-raising pop: `focus_pop` is public API and the history may be empty
      # (mirrors `rewind_focus`, which also uses `pop?`).
      old = @history.pop?
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
      # `any?` (short-circuits on the first match) is enough; the old
      # `count { ... }.zero?` always scanned the entire list.
      #
      # `window? == self` (not the raising `screen`, nor a bare truthy
      # `window?`): defensive attachment check. `#remove`/`Widget#remove` now
      # prune `@keyable` via `Window#unregister`, but a widget can still be gone
      # from the tree without that path having run for it (e.g. mid-reparent, or a
      # future caller mutating `@screen` directly), so a detached (`@screen` nil)
      # or moved-to-another-screen entry can't be assumed impossible. `screen`
      # (`window?.not_nil!`) would crash on a detached entry; a bare `window?`
      # would still select a widget on a DIFFERENT screen. Require attachment to
      # THIS screen, matching `restore_focus`/`rewind_focus`.
      #
      # `displayed_in_tree?` (not `style.visible?`) so a candidate inside a
      # hidden container is skipped even if its own flag is visible. Mirrors
      # `rewind_focus` and the mouse hit-test.
      #
      # `!el.disabled?`: a disabled widget doesn't react to keys (see
      # `_listen_keys`), so Tab/Shift+Tab must step over it (the GUI-toolkit
      # convention). Landing on it would also route through `_focus`, which sets
      # `state = :focused` and silently clears the `Disabled` state. Folding the
      # check in here (and into the skip loop below) keeps the loop's
      # termination guarantee intact: `any?` proves an acceptable candidate exists.
      return unless @keyable.any? { |el| el.window? == self && displayed_in_tree?(el) && !el.disabled? }

      # With no current focus, enter from the natural end: forward navigation
      # (`focus_next`) must land on the FIRST focusable widget, backward
      # (`focus_previous`) on the LAST. A single `-1` sentinel only gets the
      # forward case right (`-1 + 1 == 0`); for a negative offset, `-1 + -1`
      # wraps to second-from-last, never the last. So when `focused` isn't in
      # the list, pick the virtual start per direction: just-before-0 forward, 0
      # backward (so the first backward step is `-1`, wrapping to the last).
      i = if idx = @keyable.index(focused)
            idx + offset
          elsif offset > 0
            offset - 1
          else
            offset
          end

      i %= @keyable.size
      while @keyable[i].window? != self || !displayed_in_tree?(@keyable[i]) || @keyable[i].disabled?
        i += offset >= 0 ? 1 : -1
        i %= @keyable.size
      end

      focus @keyable[i]
    end

    def _focus(cur : Widget, old : Widget? = nil)
      # Re-focusing the already-focused widget has no "previous" to blur or
      # un-highlight: treating `cur` as its own `old` would set its state to
      # `:focused` (no-op) then immediately back to `:normal` (clobbering the
      # highlight), plus emit a spurious `Blur`. Reachable via the public
      # `Window#focus`/`focus_offset` (e.g. Tab with a single focusable widget
      # wraps back onto it); `Widget#focus` already guards it, but the
      # screen-level entry points do not.
      #
      # It's also not a focus *change*, so the terminating `Event::Focus` below
      # is suppressed too — emitting it would re-run focus side effects on an
      # already-focused widget (`Widget::Terminal` re-reporting focus-in to its
      # PTY, `input_on_focus` re-entering `read_input`, menu/completer handlers
      # re-firing), the same spurious-Focus defect `window_rendering.cr#_render`
      # already guards against per frame.
      refocus = old == cur
      old = nil if refocus

      # Find a scrollable ancestor if we have one.
      el = cur
      while el = el.parent
        if el.scrollable?
          break
        end
      end

      cur.state = :focused
      # Only clear the blurred widget's state when it is actually Focused.
      # `WidgetState` is single-valued: an unconditional reset re-enables a
      # widget disabled *while focused* (e.g. a wizard "Back" button) — silently
      # flipping it back to `:normal`/keyable — and clobbers a Selected/Hovered
      # state a blurred widget may legitimately hold.
      old.try { |o| o.state = :normal if o.state.focused? }

      # If we're in a scrollable element, automatically scroll the focused
      # element into view. Delegate to `#ensure_widget_visible`, the purpose-built
      # primitive that maps the descendant's row into `el`'s content space via
      # absolute tops (`cur.atop - el.atop - el.itop`) and uses
      # `#visible_content_rows` for the viewport. The previous hand-rolled math
      # used `cur.rtop`, which is relative to `cur`'s *immediate* parent — correct
      # only when `cur` is a direct child of `el`; for a deeper descendant (an
      # input inside a plain container inside a scrollable box) it omitted the
      # intervening offsets and scrolled to the wrong place (or not at all).
      if el && el.window
        cur.window.render if el.ensure_widget_visible cur
      end

      if old
        old.emit Crysterm::Event::Blur, cur
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

      cur.emit Crysterm::Event::Focus, old unless refocus
    end
  end
end
