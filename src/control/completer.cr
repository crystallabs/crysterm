require "../widget/list"
require "../mixin/popup_controller"

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
  # The attach/filter/popup plumbing is `Mixin::PopupController`; this class
  # supplies the whole-value matching policy against `#model`.
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
        st = st.with_reverse_fallback if @item_boxes[@selected]? == item
        st
      end
    end

    include Mixin::PopupController(Widget::LineEdit, Popup, String)

    def initialize(@model : Array(String) = [] of String)
    end

    # A press on the box while already focused toggles the popup. `Event::Mouse`
    # is emitted before click-to-focus is applied, so on the press that first
    # focuses the box `focused?` is still false here — that press only focuses.
    private def attach_extras(widget : Widget::LineEdit) : Nil
      @subs.on(widget, Crysterm::Event::Mouse) do |e|
        toggle if e.action.down? && widget.focused?
      end
    end

    # The per-keystroke filter pass: recompute the matches for the box's whole
    # value, then close / refresh / open the drop-down accordingly.
    private def filter_pass(widget : Widget::LineEdit) : Nil
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

    private def open : Nil
      return if @matches.empty?
      open_popup
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

    # The drop-down rows are the matched candidates themselves.
    private def popup_rows : Array(String)
      @matches
    end

    private def build_popup(widget : Widget::LineEdit) : Popup
      pop = Popup.new(
        window: widget.window,
        top: 0, left: 0,
        width: 16, height: 3,
        style: Style.new(border: true),
        overflow: Crysterm::Overflow::MoveWidget,
      )
      pop.completer = self
      pop
    end
  end
end
