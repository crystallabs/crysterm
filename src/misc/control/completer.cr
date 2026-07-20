require "../../widget/list"

module Crysterm
  # Autocompletion helper for a text input, modeled after Qt's `QCompleter`.
  #
  # A `Completer` is not a widget; it attaches to a `Widget::LineEdit` and offers
  # completions from a fixed list (its *model*) as the user types. Matches
  # appear in a drop-down `Widget::List` below the box; Down/Up move the
  # highlight (Down also opens the list), Enter or Tab inserts the highlighted
  # completion, and Escape dismisses it. The box keeps focus throughout.
  #
  # ```
  # box = Widget::LineEdit.new parent: window, top: 2, left: 2, width: 30, height: 1
  # comp = Completer.new %w[apple apricot banana blueberry cherry]
  # comp.attach box
  # ```
  #
  # Matching is case-insensitive prefix matching by default; set
  # `#case_sensitive` and/or `#mode` to change that.
  #
  # NOTE: the per-keystroke filter handler is (re)registered *after* the box's
  # own input handler so it always sees the updated value; relies on the box
  # using `input_on_focus` (the `Widget::LineEdit` default).
  class Completer
    # How a candidate is matched against the typed text.
    enum Mode
      # The candidate must start with the typed text (Qt's default).
      PrefixMatch
      # The typed text may appear anywhere in the candidate.
      SubstringMatch
    end

    # The completion candidates.
    getter model : Array(String)

    # A case-folded (downcased) mirror of `#model`, indices aligned with it, used
    # for the default case-insensitive matching. Memoized and rebuilt only when
    # `#model=` replaces the model, so a keystroke's refilter doesn't re-downcase
    # the whole model each time.
    @folded_model : Array(String)?

    def model=(model : Array(String)) : Array(String)
      @folded_model = nil
      @model = model
    end

    private def folded_model : Array(String)
      @folded_model ||= @model.map &.downcase
    end

    # Whether matching is case-sensitive (Qt's `QCompleter#caseSensitivity`).
    property? case_sensitive : Bool = false

    # The matching strategy (Qt's `QCompleter#filterMode`).
    property mode : Mode = Mode::PrefixMatch

    # Maximum rows shown before the popup scrolls (Qt's
    # `QCompleter#maxVisibleItems`).
    property max_visible_items : Int32 = 6

    # The drop-down list. A single click on a row commits it (rather than the
    # list's default two-click select-then-activate), and selection routes back
    # to the owning completer.
    class Popup < Widget::List
      @activate_on_click = true
      # Moving the pointer onto a row highlights it (box keeps focus, so the
      # list gets these as hover, not key, events).
      @hover_select = true
      # The wheel scrolls the viewport under a stationary pointer, agreeing with
      # hover-select rather than fighting it.
      @wheel_mode = Mixin::ItemView::WheelMode::ScrollViewUnderPointer
      # The drop-down never takes focus — the box keeps it the whole time, so
      # typing keeps filtering. Otherwise a wheel/click over the popup would
      # auto-focus it, blurring the box, which the completer treats as "focus
      # left" and closes the popup.
      @focus_on_click = false

      property completer : Completer?

      def activate_current
        completer.try &.commit_index(current_index)
      end

      def cancel_current
        completer.try &.close
      end

      # Parks the highlight on the first row. Called whenever the match set is
      # (re)shown, so the next Down advances to the *second* row rather than
      # merely revealing a cursor on the first.
      def reset_cursor : Nil
        self.current_index = 0
      end

      # Down/Up single-step the highlight from the currently selected row. The
      # box keeps focus throughout, so the list never sees these as its own key
      # events — the completer routes them here.
      def cursor_down : Nil
        down
      end

      def cursor_up : Nil
        up
      end

      # Arrow-key movement funnels through here so each keypress steps exactly one
      # row: the base `move_selection` would step by the raw delta, skipping rows,
      # and `current_index=` avoids recursing back into `move_selection`. The wheel
      # does *not* come through here — it has its own `#wheel_scroll`.
      def move_selection(delta : Int32) : Nil
        return if delta == 0
        self.current_index = @selected + (delta > 0 ? 1 : -1)
      end

      # The drop-down's auto-created scrollbar must not steal focus either — same
      # reason as `@focus_on_click = false` above.
      private def bind_scrollbar(sb : Widget::ScrollBar) : Widget::ScrollBar
        sb.focus_on_click = false
        super
      end

      # Reverse-video the highlighted (selected) row. `List` defers the selected
      # look to `styles.selected` / a `:selected` CSS rule, neither of which
      # covers the drop-down in the default theme.
      def render_style_for(item : Widget) : Style
        st = super
        st = st.with_reverse_fallback if @items[@selected]? == item
        st
      end
    end

    # The `Widget::LineEdit` this completer is attached to, or `nil` when
    # detached (Qt's `QCompleter#widget`).
    getter widget : Widget::LineEdit?
    @popup : Popup?
    @open = false
    @matches = [] of String

    # The box handlers installed for the completer's lifetime, torn down together
    # in `#detach`. Each `Subscription` captures the box, so teardown reaches it
    # without re-fetching `@widget` (which `#detach` may already have nilled).
    @subs = Crysterm::Subscriptions.new
    # The per-keystroke filter, re-armed at the tail on every focus. A
    # `Subscription`, so re-arming cancels the previous one.
    @filter = Crysterm::Subscription.new
    # "Click-away to dismiss" lifecycle, live only while the drop-down is open.
    # Takes no modal grab — the box must keep reacting to keystrokes.
    @dismiss : Crysterm::Overlay::DismissSession?
    # Set when the intercept handler has consumed a key, so the filter handler
    # skips that same keypress.
    @suppress_filter = false
    # The box value the per-keystroke filter last acted on. Used to dedupe:
    # a keypress that leaves `#value` unchanged (cursor movement) never reopens
    # a dismissed popup — only a text change does. `#close` records the current
    # value here so Escape-then-arrow stays closed; the attach/detach/commit
    # paths reset it to nil so retyping the same text after a commit still
    # reopens on the change.
    @last_filter_value : String?

    def initialize(@model : Array(String) = [] of String)
    end

    # Attaches the completer to *widget*. Installs the navigation interceptor
    # immediately, and the per-keystroke filter handler so that it runs after the
    # box's input handler (now if already focused, otherwise on first focus).
    def attach(widget : Widget::LineEdit) : Nil
      detach
      @widget = widget
      @last_filter_value = nil

      # Runs *before* the box's input handler: when the popup is open it owns the
      # navigation keys (and neutralizes them so the box ignores them); when
      # closed, Down opens the popup.
      @subs.on(widget, Crysterm::Event::KeyPress, at: ::EventHandler.at_beginning) do |e|
        handle_intercept e
      end

      # The filter must be (re)installed at the tail on *every* focus, not just
      # the first: the box re-registers its own input handler each time it
      # re-enters read mode, appending it after ours, so a once-installed filter
      # would from the second focus on run before the box updates `#value` and
      # miss the keystroke.
      @subs.on(widget, Crysterm::Event::FocusIn) { install_filter widget }
      install_filter widget if widget.focused?

      # A press on the box while already focused toggles the popup. `Event::Mouse`
      # is emitted before click-to-focus is applied, so on the press that first
      # focuses the box `focused?` is still false here — that press only focuses.
      @subs.on(widget, Crysterm::Event::Mouse) do |e|
        toggle if e.action.down? && widget.focused?
      end

      # Don't leave an orphaned popup behind when focus leaves the box.
      @subs.on(widget, Crysterm::Event::FocusOut) { close }

      # Tear down with the box: the popup is a *window* child, so destroying the
      # box alone would leave it in the window's children forever, with the
      # completer referencing a dead widget.
      @subs.on(widget, Crysterm::Event::Destroy) { detach }
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
    end

    # Whether the completion popup is currently shown.
    def open? : Bool
      @open
    end

    # The per-keystroke filter handler. Re-registered at the tail (removing any
    # prior one) so it always runs after the box's input handler and sees the
    # post-keystroke `#value`.
    private def install_filter(widget : Widget::LineEdit) : Nil
      # `#on` cancels the previously-armed filter, so re-focusing can't stack them.
      @filter.on(widget, Crysterm::Event::KeyPress, at: ::EventHandler.at_end) do |_|
        if @suppress_filter
          @suppress_filter = false
        else
          refilter
          val = widget.value
          if @matches.empty? || (@matches.size == 1 && @matches.first == val)
            close
          elsif val == @last_filter_value
            # Value unchanged since the last filter pass (e.g. cursor movement):
            # keep an open popup fresh, but never reopen a dismissed one.
            refresh if @open
          else
            @last_filter_value = val
            @open ? refresh : open
          end
        end
      end
    end

    private def handle_intercept(e : Crysterm::Event::KeyPress) : Nil
      return if @model.empty?
      if @open
        case e.key
        when Tput::Key::Down   then move_popup &.cursor_down; consume e
        when Tput::Key::Up     then move_popup &.cursor_up; consume e
        when Tput::Key::Enter  then accept_current; consume e
        when Tput::Key::Tab    then accept_current; consume e
        when Tput::Key::Escape then close; consume e
        end
      elsif e.key == Tput::Key::Down
        # Down opens the popup. `refilter` yields the whole model for an empty
        # box (combo-box style), so the user can browse without typing.
        refilter
        unless @matches.empty?
          open
          consume e
        end
      end
    end

    # Moves the popup's highlight (Up/Down) and re-renders — `List#current_index=`
    # updates the cursor but doesn't itself repaint.
    private def move_popup(&block : Popup ->) : Nil
      return unless pop = @popup
      block.call pop
      pop.request_render
    end

    # Stops the keypress: accepts it (so it doesn't bubble to ancestors) and
    # blanks it so the box's input handler, which runs afterwards, ignores it.
    private def consume(e : Crysterm::Event::KeyPress) : Nil
      e.accept
      e.key = nil
      e.char = '\u0000'
      @suppress_filter = true
    end

    # The completions for *text* under the current `#mode`/`#case_sensitive?`
    # settings (empty for empty input).
    def completions(text : String) : Array(String)
      return [] of String if text.empty?
      if case_sensitive?
        needle = text
        @model.select do |c|
          mode.prefix_match? ? c.starts_with?(needle) : c.includes?(needle)
        end
      else
        needle = text.downcase
        folded = folded_model
        result = [] of String
        folded.each_with_index do |hay, i|
          match = mode.prefix_match? ? hay.starts_with?(needle) : hay.includes?(needle)
          result << @model[i] if match
        end
        result
      end
    end

    # Recomputes `@matches` from the box's current value. An empty box yields the
    # whole model (combo-box style), so clearing the text reopens the full list
    # instead of dismissing the popup.
    private def refilter : Nil
      val = @widget.try(&.value) || ""
      @matches = val.empty? ? @model.dup : completions(val)
    end

    # Loads the current `@matches` into *pop*, re-parks the highlight on the
    # first row, and repositions the drop-down under *widget*. Shared by `#open`
    # and `#refresh`.
    private def populate(pop : Popup, widget : Widget::LineEdit) : Nil
      pop.items = @matches
      pop.reset_cursor
      position pop, widget
    end

    private def open : Nil
      return unless widget = @widget
      return if @matches.empty?
      pop = ensure_popup widget
      populate pop, widget
      pop.show
      pop.to_front
      @open = true
      # Dismiss on a press outside both the drop-down and its box (a press on
      # the box itself is "inside" — its own handler toggles the list). No modal
      # grab: the box keeps focus and keeps filtering as you type.
      s = Crysterm::Overlay::DismissSession.new(
        widget.window, grab_owner: nil,
        inside: ->(x : Int32, y : Int32) {
          (@popup.try(&.contains_point?(x, y)) || false) || (@widget.try(&.contains_point?(x, y)) || false)
        }) { close }
      s.open
      @dismiss = s
      widget.request_render
    end

    private def refresh : Nil
      return unless widget = @widget
      if pop = @popup
        populate pop, widget
        widget.request_render
      end
    end

    # Toggles the popup: opens it on the current matches (the whole model for an
    # empty box), or closes it if already open.
    private def toggle : Nil
      if @open
        close
      else
        refilter
        open unless @matches.empty?
      end
    end

    # Hides the popup (no change to the box). Public so the popup's
    # `cancel_current` can route an Escape/outside dismissal back here.
    def close : Nil
      return unless @open
      @open = false
      # Record the value at dismissal so a following non-modifying key (cursor
      # movement, unchanged text) doesn't reopen the popup; only a real text
      # change will differ from this and reopen. Nil-resetting here instead
      # would reintroduce the reopen-on-Escape bug.
      @last_filter_value = @widget.try &.value
      @popup.try &.hide
      @dismiss.try &.close
      @dismiss = nil
      @widget.try &.request_render
    end

    # Inserts the completion at *index* into the box and closes the popup. Public
    # so the popup can commit the row the user clicked.
    def commit_index(index : Int32) : Nil
      if (widget = @widget) && (c = @matches[index]?)
        widget.value = c
      end
      close
      # Retyping the committed text is a real edit that should reopen, so don't
      # let `#close`'s recorded value suppress it.
      @last_filter_value = nil
    end

    private def accept_current : Nil
      commit_index(@popup.try(&.current_index) || 0)
    end

    private def ensure_popup(widget : Widget::LineEdit) : Popup
      # A cross-window reparent of the box strands the cached popup on the old
      # window (it is a *window* child): reopening would render the list over
      # there while placement and the dismiss watcher use the new window. Drop
      # the stale popup and rebuild on the box's current window.
      if (stale = @popup) && stale.window? != widget.window?
        Widget.destroy_satellite stale
        @popup = nil
      end
      @popup ||= begin
        pop = Popup.new(
          window: widget.window,
          top: 0, left: 0,
          width: 16, height: 3,
          style: Style.new(border: true),
          overflow: Crysterm::Overflow::MoveWidget,
        )
        pop.completer = self
        # The wheel scrolls the list while it's open. A wheel over a *row* is
        # handled by `List`'s per-item handler; this covers a wheel over the
        # popup's border/padding, going through the same `#wheel_scroll` so both
        # behave identically.
        pop.on(Crysterm::Event::Mouse) do |e|
          if e.action.wheel_down?
            pop.wheel_scroll 1; e.accept; pop.request_render
          elsif e.action.wheel_up?
            pop.wheel_scroll -1; e.accept; pop.request_render
          end
        end
        widget.window.append pop
        pop.hide
        pop
      end
    end

    private def position(pop : Widget::List, widget : Widget::LineEdit) : Nil
      rows = Math.min(Math.max(@matches.size, 1), @max_visible_items)
      h = rows + 2 # border
      pop.height = h
      w = Math.max(widget.awidth, 8)
      pop.width = w
      # Prefer directly below the field; flip above only when the list can't fit
      # below. `Overlay.place_child` owns the fit choice, the on-window clamp, and
      # the absolute→window-local inset conversion the window-appended popup needs.
      Overlay.place_child(pop, {widget.aleft, widget.atop, widget.awidth, widget.aheight},
        {w, h}, [Overlay::Side::Below, Overlay::Side::Above])
    rescue
      # Not laid out yet — keep defaults.
    end
  end
end
