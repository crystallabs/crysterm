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

      property completer : Completer?

      def enter_selected
        completer.try &.commit_index(selected)
      end

      def cancel_selected
        completer.try &.close
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

      if widget.focused?
        install_filter widget
      else
        @ev_focus = widget.on(Crysterm::Event::Focus) do |_|
          install_filter widget
          # One-shot: the box's input handler is now in place.
          @ev_focus.try { |w| widget.off Crysterm::Event::Focus, w }
          @ev_focus = nil
        end
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
      end
      @intercept = @filter = nil
      @ev_focus = nil
      @ev_blur = nil
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

    # The per-keystroke filter handler. Registered at the tail so the box has
    # already updated its `#value` by the time it runs.
    private def install_filter(widget : Widget::TextBox) : Nil
      return if @filter
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
        when Tput::Key::Down  then @popup.try &.down; consume e
        when Tput::Key::Up    then @popup.try &.up; consume e
        when Tput::Key::Enter then accept_current; consume e
        when Tput::Key::Tab   then accept_current; consume e
        when Tput::Key::Escape then close; consume e
        end
      elsif e.key == Tput::Key::Down
        refilter
        unless @matches.empty?
          open
          consume e
        end
      end
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

    # Recomputes `@matches` from the box's current value.
    private def refilter : Nil
      @matches = completions(@widget.try(&.value) || "")
    end

    private def open : Nil
      return unless widget = @widget
      return if @matches.empty?
      pop = ensure_popup widget
      pop.set_items @matches
      pop.selekt 0
      position pop, widget
      pop.show
      pop.front!
      @open = true
      widget.request_render
    end

    private def refresh : Nil
      return unless widget = @widget
      if pop = @popup
        pop.set_items @matches
        pop.selekt 0
        position pop, widget
        widget.request_render
      end
    end

    # Hides the popup (no change to the box). Public so the popup's
    # `cancel_selected` can route an Escape/outside dismissal back here.
    def close : Nil
      return unless @open
      @open = false
      @popup.try &.hide
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
