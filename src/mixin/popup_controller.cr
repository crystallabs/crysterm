module Crysterm
  module Mixin
    # Shared plumbing for a non-widget *popup controller*: an object that
    # attaches to an editor widget and drives a drop-down suggestion list over
    # it while the editor keeps focus (and keeps filtering) the whole time —
    # `Crysterm::Completer` over a `Widget::LineEdit`, and
    # `Widget::Chat::Autocomplete` over a `Widget::PlainTextEdit`.
    #
    # The mixin owns the mechanism: attach/detach handler lifecycle, the
    # before-the-editor key interceptor and after-the-editor keystroke filter,
    # popup construction/caching/placement, open/close with the click-away
    # dismiss session, and highlight movement. The including controller keeps
    # only its policy, supplied as plainly-named methods (duck-typed, not
    # `abstract def` — see the NOTE in `Mixin::Popup` on the multi-includer
    # codegen crash):
    #
    #   * `filter_pass(widget : EditorT)` — the per-keystroke reaction, run
    #     after the editor has applied the key: recompute `@matches` and
    #     open/refresh/close accordingly;
    #   * `handle_intercept(e : Event::KeyPress)` — key ownership, run before
    #     the editor sees the key: navigation/accept/dismiss while open (each
    #     consumed via `#consume`), plus any open-the-popup gesture;
    #   * `commit_index(index : Int32)` — apply the match at *index* to the
    #     editor and `#close` (public: the popup routes row clicks here);
    #   * `popup_rows : Array(String)` — the list rows for `@matches`;
    #   * `build_popup(widget : EditorT) : PopupT` — construct the popup (a
    #     `Completer::Popup` or subclass) and set its back-pointer; the mixin
    #     wires the wheel handler and parents it afterwards.
    #
    # Optional hooks, no-ops by default: `attach_extras(widget)` (extra
    # `@subs`-routed handlers) and `detach_reset` (extra per-controller state
    # cleared on detach).
    #
    # Type arguments: *EditorT* is the editor widget class, *PopupT* the
    # drop-down class, *MatchT* the element type of `@matches`.
    module PopupController(EditorT, PopupT, MatchT)
      # The editor widget this controller is attached to, or `nil` when
      # detached (Qt's `QCompleter#widget`).
      getter widget : EditorT?

      # Maximum rows shown before the drop-down scrolls (Qt's
      # `QCompleter#maxVisibleItems`).
      property max_visible_items : Int32 = 6

      @popup : PopupT?
      @open = false

      # The current match set, recomputed by the includer (`filter_pass` and
      # any open gesture) and read back by its `popup_rows`/`commit_index`.
      @matches = [] of MatchT

      # The editor handlers installed for the controller's lifetime, torn down
      # together in `#detach`. Each `Subscription` captures the editor, so
      # teardown reaches it without re-fetching `@widget` (which `#detach` may
      # already have nilled).
      @subs = ::Crysterm::Subscriptions.new
      # The per-keystroke filter, re-armed at the tail on every focus. A
      # `Subscription`, so re-arming cancels the previous one.
      @filter = ::Crysterm::Subscription.new
      # "Click-away to dismiss" lifecycle, live only while the drop-down is
      # open. Takes no modal grab — the editor must keep reacting to
      # keystrokes.
      @dismiss : ::Crysterm::Overlay::DismissSession?
      # Set when the intercept handler has consumed a key, so the filter
      # handler skips that same keypress.
      @suppress_filter = false
      # The editor value the per-keystroke filter last acted on / the popup
      # was dismissed at. Used to dedupe: a keypress that leaves the value
      # unchanged (cursor movement) never reopens a dismissed popup — only a
      # text change does. `#close` records the current value here so
      # Escape-then-arrow stays closed; the attach/detach/commit paths reset
      # it to nil so retyping the same text after a commit still reopens on
      # the change.
      @last_filter_value : String?

      # Attaches the controller to *widget*. Installs the navigation
      # interceptor immediately, and the per-keystroke filter handler so that
      # it runs after the editor's input handler (now if already focused,
      # otherwise on first focus).
      def attach(widget : EditorT) : Nil
        detach
        @widget = widget
        @last_filter_value = nil

        # Runs *before* the editor's input handler: while the popup is open it
        # owns the navigation keys (and blanks them so the editor ignores
        # them); the includer's `handle_intercept` decides the rest.
        @subs.on(widget, Event::KeyPress, at: ::EventHandler.at_beginning) do |e|
          handle_intercept e
        end

        # The filter must be (re)installed at the tail on *every* focus, not
        # just the first: the editor re-registers its own input handler each
        # time it re-enters read mode, appending it after ours, so a
        # once-installed filter would from the second focus on run before the
        # editor updates its value and miss the keystroke.
        @subs.on(widget, Event::FocusIn) { install_filter widget }
        install_filter widget if widget.focused?

        attach_extras widget

        # Don't leave an orphaned popup behind when focus leaves the editor.
        @subs.on(widget, Event::FocusOut) { close }

        # Tear down with the editor: the popup is a *window* child, so
        # destroying the editor alone would leave it in the window's children
        # forever, with the controller referencing a dead widget.
        @subs.auto_dispose(widget) { detach }
      end

      # Hook for controller-specific handlers, registered during `#attach`.
      # Route them through `@subs` so they tear down with the rest.
      private def attach_extras(widget : EditorT) : Nil
      end

      # Removes all handlers and tears down the popup.
      def detach : Nil
        @subs.off
        @filter.off
        @dismiss.try &.close
        @dismiss = nil
        Widget.destroy_satellite @popup
        @popup = nil
        @open = false
        @widget = nil
        @last_filter_value = nil
        detach_reset
      end

      # Hook for controller-specific state cleared on `#detach`.
      private def detach_reset : Nil
      end

      # Whether the completion popup is currently shown.
      def open? : Bool
        @open
      end

      # The per-keystroke filter handler. Re-registered at the tail (removing
      # any prior one) so it always runs after the editor's input handler and
      # sees the post-keystroke value; the includer's `filter_pass` does the
      # actual work.
      private def install_filter(widget : EditorT) : Nil
        # `#on` cancels the previously-armed filter, so re-focusing can't
        # stack them.
        @filter.on(widget, Event::KeyPress, at: ::EventHandler.at_end) do |_|
          if @suppress_filter
            @suppress_filter = false
          else
            filter_pass widget
          end
        end
      end

      # Moves the popup's highlight (Up/Down) and re-renders —
      # `List#current_index=` updates the cursor but doesn't itself repaint.
      private def move_popup(&block : PopupT ->) : Nil
        return unless pop = @popup
        block.call pop
        pop.update!
      end

      # Stops the keypress: accepts it (so it doesn't bubble to ancestors) and
      # blanks it so the editor's input handler, which runs afterwards,
      # ignores it.
      private def consume(e : Event::KeyPress) : Nil
        e.accept
        e.key = nil
        e.char = '\u0000'
        @suppress_filter = true
      end

      # Loads the includer's rows for the current `@matches` into *pop*,
      # re-parks the highlight on the first row, and repositions the drop-down
      # against *widget*. Shared by `#open_popup` and `#refresh`.
      private def populate(pop : PopupT, widget : EditorT) : Nil
        pop.items = popup_rows
        pop.reset_cursor
        position pop, widget
      end

      # Shows the popup on the current `@matches` and arms the click-away
      # watcher.
      private def open_popup : Nil
        return unless widget = @widget
        pop = ensure_popup widget
        populate pop, widget
        pop.show
        pop.to_front
        @open = true
        # Dismiss on a press outside both the drop-down and its editor (a
        # press on the editor itself is "inside" — e.g. the completer's own
        # handler toggles the list). No modal grab: the editor keeps focus and
        # keeps filtering as you type.
        s = ::Crysterm::Overlay::DismissSession.new(
          widget.window, grab_owner: nil,
          inside: ->(x : Int32, y : Int32) {
            (@popup.try(&.contains_point?(x, y)) || false) || (@widget.try(&.contains_point?(x, y)) || false)
          }) { close }
        s.open
        @dismiss = s
        widget.update!
      end

      # Re-populates and re-places an already-created popup.
      private def refresh : Nil
        return unless widget = @widget
        if pop = @popup
          populate pop, widget
          widget.update!
        end
      end

      # Hides the popup (no change to the editor). Public so the popup's
      # `cancel_current` can route an Escape/outside dismissal back here.
      def close : Nil
        return unless @open
        @open = false
        # Record the value at dismissal so a following non-modifying key
        # (cursor movement, unchanged text) doesn't reopen the popup; only a
        # real text change will differ from this and reopen. Nil-resetting
        # here instead would reintroduce the reopen-on-Escape bug.
        @last_filter_value = @widget.try &.value
        @popup.try &.hide
        @dismiss.try &.close
        @dismiss = nil
        @widget.try &.update!
      end

      # Commits the highlighted row (Enter/Tab) via the includer's
      # `commit_index`.
      private def accept_current : Nil
        commit_index(@popup.try(&.current_index) || 0)
      end

      # The cached popup, (re)built via the includer's `build_popup` when
      # missing or stranded.
      private def ensure_popup(widget : EditorT) : PopupT
        # A cross-window reparent of the editor strands the cached popup on
        # the old window (it is a *window* child): reopening would render the
        # list over there while placement and the dismiss watcher use the new
        # window. Drop the stale popup and rebuild on the editor's current
        # window.
        if (stale = @popup) && stale.window? != widget.window?
          Widget.destroy_satellite stale
          @popup = nil
        end
        @popup ||= begin
          pop = build_popup widget
          # The wheel scrolls the list while it's open. A wheel over a *row*
          # is handled by `List`'s per-item handler; this covers a wheel over
          # the popup's border/padding, going through the same `#wheel_scroll`
          # so both behave identically.
          pop.on(Event::Mouse) do |e|
            if e.action.wheel_down?
              pop.wheel_scroll 1; e.accept; pop.update!
            elsif e.action.wheel_up?
              pop.wheel_scroll -1; e.accept; pop.update!
            end
          end
          widget.window.append pop
          pop.hide
          pop
        end
      end

      # Places the drop-down against the editor: full editor width, preferring
      # directly below and flipping above only when the list can't fit below.
      private def position(pop : PopupT, widget : EditorT) : Nil
        rows = Math.min(Math.max(@matches.size, 1), @max_visible_items)
        # Outer height = visible rows plus the popup's own border/padding
        # (`#ivertical`), so a themed/padded popup sizes correctly — mirrors
        # ComboBox#place_popup's `pop.visible_rows + pop.ivertical`.
        # `ivertical` is 2 for the default `Style.new(border: true)` popup
        # (1-cell top/bottom border, no padding).
        h = rows + pop.ivertical
        pop.height = h
        w = Math.max(widget.awidth, 8)
        pop.width = w
        # `Overlay.place_child` owns the below/above fit choice, the on-window
        # clamp, and the absolute→window-local inset conversion the
        # window-appended popup needs.
        #
        # Anchor on the editor's *painted* rect (`Widget#painted_rect`, with a
        # pre-render layout fallback), not its layout coords: inside a
        # scrolled/child_base ancestor the two diverge by the ancestor's
        # scroll base, and the popup (a window child) is painted exactly where
        # we put it — so layout coords would open the list detached from the
        # visible editor. Mirrors ComboBox#place_popup /
        # DateEdit#position_popup.
        Overlay.place_child(pop, widget.painted_rect, {w, h}, Overlay::BELOW_ABOVE)
      rescue
        # Not laid out yet — keep defaults; render re-runs with real geometry.
      end
    end
  end
end
