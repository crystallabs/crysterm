require "../../widget/list"

module Crysterm
  # Autocompletion helper for a text input, modeled after Qt's `QCompleter`.
  #
  # A `Completer` is not a widget; it attaches to a `Widget::TextBox` and offers
  # completions from a fixed list (its *model*) as the user types. The matches
  # appear in a drop-down `Widget::List` below the box; Down/Up move the
  # highlight (Down also opens the list), Enter or Tab inserts the highlighted
  # completion, and Escape dismisses it. Typing keeps filtering; the box keeps
  # focus throughout.
  #
  # ```
  # box = Widget::TextBox.new parent: screen, top: 2, left: 2, width: 30, height: 1
  # comp = Completer.new %w[apple apricot banana blueberry cherry]
  # comp.attach box
  # ```
  #
  # Matching is case-insensitive prefix matching by default; set
  # `#case_sensitive` and/or `#mode` to change that.
  #
  # NOTE The per-keystroke filter handler is (re)registered *after* the text
  # box's own input handler so it always sees the updated value; this relies on
  # the box using `input_on_focus` (the `Widget::TextBox` default).
  class Completer
    # How a candidate is matched against the typed text.
    enum Mode
      # The candidate must start with the typed text (Qt's default).
      PrefixMatch
      # The typed text may appear anywhere in the candidate.
      SubstringMatch
    end

    # The completion candidates.
    property model : Array(String)

    # Whether matching is case-sensitive (Qt's `QCompleter#caseSensitivity`).
    property? case_sensitive : Bool = false

    # The matching strategy (Qt's `QCompleter#filterMode`).
    property mode : Mode = Mode::PrefixMatch

    # Maximum rows shown before the popup scrolls.
    property max_visible : Int32 = 6

    # The drop-down list. A single click on a row commits it (rather than the
    # list's default two-click select-then-activate), and selection routes back
    # to the owning completer.
    class Popup < Widget::List
      @activate_on_click = true
      # Moving the pointer onto a row highlights it (the box keeps focus, so the
      # list gets these as hover, not key, events).
      @hover_select = true

      property completer : Completer?

      # Whether a row is actively highlighted. The popup opens with *no* cursor —
      # `List#selected` is 0, but showing it as selected would be a lie (the user
      # hasn't chosen anything) and would make the first Down land on the *second*
      # row. The cursor only appears once the user navigates (`#cursor_down`/
      # `#cursor_up`) or hovers a row.
      getter? cursor_shown : Bool = false

      def enter_selected
        completer.try &.commit_index(selected)
      end

      def cancel_selected
        completer.try &.close
      end

      # Clears the cursor (back to the "nothing highlighted" state) and parks the
      # internal selection at the top. Called whenever the match set is (re)shown.
      def reset_cursor : Nil
        @cursor_shown = false
        selekt 0
      end

      # Down: reveal the cursor on the first row on the first press, then step
      # down. Up: reveal it on the last row first, then step up.
      def cursor_down : Nil
        @cursor_shown ? down : reveal(0)
      end

      def cursor_up : Nil
        @cursor_shown ? up : reveal(@items.size - 1)
      end

      private def reveal(index : Int) : Nil
        @cursor_shown = true
        selekt index
      end

      # Pointer onto a row counts as choosing it, so show the cursor there.
      def hover_item(i : Int)
        @cursor_shown = true
        super
      end

      # Reverse-video the highlighted row, but only once a cursor actually exists.
      # `List` defers the selected look to `styles.selected` / a `:selected` CSS
      # rule, neither of which covers the drop-down in the default theme, so the
      # cursor row would otherwise be indistinguishable.
      def render_style_for(item : Widget) : Style
        st = super
        if cursor_shown? && @items[@selected]? == item
          st = st.dup
          st.reverse = true
        end
        st
      end
    end

    @widget : Widget::TextBox?
    @popup : Popup?
    @open = false
    @matches = [] of String

    # Key-handler wrappers, kept so `#detach` can remove them.
    @intercept : Crysterm::Event::KeyPress::Wrapper?
    @filter : Crysterm::Event::KeyPress::Wrapper?
    @ev_focus : Crysterm::Event::Focus::Wrapper?
    @ev_blur : Crysterm::Event::Blur::Wrapper?
    @ev_click : Crysterm::Event::Mouse::Wrapper?
    # Screen-level "click-away to dismiss" watcher, live only while the drop-down
    # is open (the same `Screen#on_press_outside` the pop-up menus use).
    @ev_outside : Crysterm::Event::Mouse::Wrapper?
    # Set when the intercept handler has consumed a key, so the (later) filter
    # handler skips that same keypress.
    @suppress_filter = false

    def initialize(@model : Array(String) = [] of String)
    end

    # Attaches the completer to *widget*. Installs the navigation interceptor
    # immediately, and the per-keystroke filter handler so that it runs after the
    # box's input handler (now if already focused, otherwise on first focus).
    def attach(widget : Widget::TextBox) : Nil
      detach
      @widget = widget

      # Runs *before* the box's input handler: when the popup is open it owns the
      # navigation keys (and neutralizes them so the box ignores them); when
      # closed, Down opens the popup.
      @intercept = widget.on(Crysterm::Event::KeyPress, at: ::EventHandler.at_beginning) do |e|
        handle_intercept e
      end

      # (Re)install the filter at the tail on *every* focus, not just the first.
      # The box re-registers its own input handler each time it (re)enters read
      # mode (`#read_input`), appending it after our filter — so a once-installed
      # filter would, from the second focus on, run *before* the box updates
      # `#value` and keep seeing the pre-keystroke text (typing wouldn't open the
      # popup). Re-appending on each focus keeps the filter last.
      @ev_focus = widget.on(Crysterm::Event::Focus) { install_filter widget }
      install_filter widget if widget.focused?

      # A press on the box while it is *already* focused toggles the popup. The
      # `Event::Mouse` is emitted before click-to-focus is applied, so on the
      # press that first focuses the box `focused?` is still false here — that
      # press only focuses, it doesn't toggle.
      @ev_click = widget.on(Crysterm::Event::Mouse) do |e|
        toggle if e.action.down? && widget.focused?
      end

      # Don't leave an orphaned popup behind when focus leaves the box.
      @ev_blur = widget.on(Crysterm::Event::Blur) { close }
    end

    # Removes all handlers and tears down the popup.
    def detach : Nil
      if w = @widget
        @intercept.try { |h| w.off Crysterm::Event::KeyPress, h }
        @filter.try { |h| w.off Crysterm::Event::KeyPress, h }
        @ev_focus.try { |h| w.off Crysterm::Event::Focus, h }
        @ev_blur.try { |h| w.off Crysterm::Event::Blur, h }
        @ev_click.try { |h| w.off Crysterm::Event::Mouse, h }
        @ev_outside.try { |h| w.screen?.try &.off Crysterm::Event::Mouse, h }
      end
      @intercept = @filter = nil
      @ev_focus = nil
      @ev_blur = nil
      @ev_click = nil
      @ev_outside = nil
      if pop = @popup
        pop.screen?.try &.remove pop
        pop.destroy
      end
      @popup = nil
      @open = false
      @widget = nil
    end

    # Whether the completion popup is currently shown.
    def open? : Bool
      @open
    end

    # The per-keystroke filter handler. Re-registered at the tail (removing any
    # prior one) so it always runs *after* the box's input handler and therefore
    # sees the post-keystroke `#value`.
    private def install_filter(widget : Widget::TextBox) : Nil
      @filter.try { |h| widget.off Crysterm::Event::KeyPress, h }
      @filter = widget.on(Crysterm::Event::KeyPress, at: ::EventHandler.at_end) do |_|
        if @suppress_filter
          @suppress_filter = false
        else
          refilter
          if @matches.empty? || (@matches.size == 1 && @matches.first == widget.value)
            close
          else
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
        # Down opens the popup. `refilter` drops the whole model for an empty box
        # (combo-box style), so the user can browse all candidates without typing.
        refilter
        unless @matches.empty?
          open
          consume e
        end
      end
    end

    # Moves the popup's highlight (Up/Down) and re-renders so the change is
    # actually visible — `List#selekt` updates the cursor but doesn't itself
    # repaint. (The caller still `consume`s the key so the box doesn't also act
    # on it.)
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
    # settings (empty for empty input). Qt's `QCompleter` exposes the analogous
    # match list via its completion model.
    def completions(text : String) : Array(String)
      return [] of String if text.empty?
      needle = case_sensitive? ? text : text.downcase
      @model.select do |c|
        hay = case_sensitive? ? c : c.downcase
        mode.prefix_match? ? hay.starts_with?(needle) : hay.includes?(needle)
      end
    end

    # Recomputes `@matches` from the box's current value. An empty box yields the
    # whole model (combo-box style) rather than nothing, so clearing the text
    # reopens the full list instead of dismissing the popup.
    private def refilter : Nil
      val = @widget.try(&.value) || ""
      @matches = val.empty? ? @model.dup : completions(val)
    end

    private def open : Nil
      return unless widget = @widget
      return if @matches.empty?
      pop = ensure_popup widget
      pop.set_items @matches
      pop.reset_cursor # open with no row pre-highlighted
      position pop, widget
      pop.show
      pop.front!
      @open = true
      # Dismiss on a press outside both the drop-down and its box (a press on the
      # box itself is "inside" — its own handler toggles the list).
      @ev_outside ||= widget.screen.on_press_outside(->(x : Int32, y : Int32) {
        (@popup.try(&.contains_point?(x, y)) || false) || (@widget.try(&.contains_point?(x, y)) || false)
      }) { close }
      widget.request_render
    end

    private def refresh : Nil
      return unless widget = @widget
      if pop = @popup
        pop.set_items @matches
        pop.reset_cursor # a changed match set starts again with no highlight
        position pop, widget
        widget.request_render
      end
    end

    # Toggles the popup: opens it on the current matches (the whole model for an
    # empty box), or closes it if already open. Used by the click-to-toggle on an
    # already-focused box.
    private def toggle : Nil
      if @open
        close
      else
        refilter
        open unless @matches.empty?
      end
    end

    # Hides the popup (no change to the box). Public so the popup's
    # `cancel_selected` can route an Escape/outside dismissal back here.
    def close : Nil
      return unless @open
      @open = false
      @popup.try &.hide
      @ev_outside.try { |h| @widget.try &.screen?.try &.off Crysterm::Event::Mouse, h }
      @ev_outside = nil
      @widget.try &.request_render
    end

    # Inserts the completion at *index* into the box and closes the popup. Public
    # so the popup can commit the row the user clicked.
    def commit_index(index : Int32) : Nil
      if (widget = @widget) && (c = @matches[index]?)
        widget.value = c
      end
      close
    end

    private def accept_current : Nil
      commit_index(@popup.try(&.selected) || 0)
    end

    private def ensure_popup(widget : Widget::TextBox) : Popup
      @popup ||= begin
        pop = Popup.new(
          screen: widget.screen,
          top: 0, left: 0,
          width: 16, height: 3,
          style: Style.new(border: true),
          overflow: Crysterm::Overflow::MoveWidget,
        )
        pop.completer = self
        # The wheel moves the highlight while the list is open (the box keeps
        # focus, so the list won't get these as key events).
        pop.on(Crysterm::Event::Mouse) do |e|
          if e.action.wheel_down?
            pop.down; e.accept; pop.request_render
          elsif e.action.wheel_up?
            pop.up; e.accept; pop.request_render
          end
        end
        widget.screen.append pop
        pop.hide
        pop
      end
    end

    private def position(pop : Widget::List, widget : Widget::TextBox) : Nil
      begin
        pop.top = widget.atop + widget.aheight
        pop.left = widget.aleft
        pop.width = Math.max(widget.awidth, 8)
      rescue
        # Not laid out yet — keep defaults.
      end
      rows = Math.min(Math.max(@matches.size, 1), @max_visible)
      pop.height = rows + 2 # + border
    end
  end
end
