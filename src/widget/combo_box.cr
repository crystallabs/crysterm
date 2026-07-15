require "./input"
require "./abstract_item_view"
require "../mixin/item_view"
require "../mixin/popup"

module Crysterm
  class Widget
    # Drop-down selector, modeled after Qt's `QComboBox`.
    #
    # Closed, it shows the current value followed by a `▾` marker. Opening it
    # (Enter / Space / Down / click) drops a `List` popup below the box;
    # choosing an item closes the popup and updates the value. While closed,
    # Up/Down cycle the value in place.
    #
    # With `#editable?` the box also accepts free text: typing filters the popup
    # to the matching options (case-insensitive substring), Up/Down move the
    # highlight, and Enter commits the highlighted option — or the typed text
    # itself when nothing matches.
    #
    # Two signals, split the way Qt splits them: `Event::CurrentChanged` (the new
    # `#current_index`) whenever the value changes, however it changed — Qt's
    # `currentIndexChanged`; and `Event::Action` (the chosen text) only when the
    # *user* picks or cycles a value — Qt's `activated`. A programmatic
    # `#current_index=` or `#reset` therefore reports the change without
    # impersonating a user action.
    #
    # The collection is called `#options` (not `items`, which `Widget` already
    # uses for child widgets), but the per-item verbs are Qt's `QComboBox` ones:
    # `#add_item`/`#insert_item`/`#remove_item`/`#clear`/`#count`/`#item_text`.
    #
    # <!-- widget-examples:capture v1 -->
    # ![ComboBox screenshot](../../tests/widget/combo_box/combo_box.5s.apng)
    # <!-- /widget-examples:capture -->
    class ComboBox < Input
      # Pop-up lifecycle (open flag, modal grab, outside-click dismissal, grab
      # region, teardown). Provides `#open?`/`#show_popup`/`#teardown_popup`/
      # `#grab_contains?`; we supply `#popup_widget` and `#close`.
      include Mixin::Popup

      # A combo is fixed-size: it honors its given `width` rather than shrinking
      # to the `"value ▾"` content like an `Input` would — else its clickable
      # area collapses to a few cells.
      @shrink_to_fit = false

      # The popup drop-down list. An `AbstractItemView` (sibling of `List`,
      # reusing row machinery via `Mixin::ItemView`). Overrides commit/cancel
      # hooks so a choice routes back to the owning combo instead of emitting
      # list item events.
      class Popup < AbstractItemView
        include Mixin::ItemView
        # The drop-down is an overlay: structural border at the unstyled floor,
        # theme-overridable via the cascade.
        include Mixin::Overlay

        # A single click on any row commits it.
        @activate_on_click = true

        # Moving the pointer onto a row highlights it, no click required (like a
        # desktop combo drop-down). Wired by `Mixin::ItemView#create_item`;
        # keyboard navigation and click-to-commit are unaffected.
        @hover_select = true

        # The wheel scrolls the viewport under a stationary pointer (see
        # `Mixin::ItemView#wheel_scroll`), so it and hover-select agree instead
        # of fighting over the selection.
        @wheel_mode = Mixin::ItemView::WheelMode::ScrollViewUnderPointer

        # How many option rows the owning combo wants visible. The popup's outer
        # height is this plus its own border/padding (`#ivertical`), set by
        # `ComboBox#position_popup` and re-applied at render (see `#render`).
        property visible_rows : Int32 = 1

        property combo : ComboBox?

        def enter_selected
          combo.try &.commit selected
        end

        def cancel_selected
          combo.try &.close
        end

        # Re-fits the popup's outer height to `#visible_rows` plus its own
        # border/padding (`#ivertical`) at render, after the CSS cascade has
        # resolved the border (mirrors `Widget::Menu#autosize`). No assumption
        # of a 1-cell border. `height=` is a no-op when unchanged.
        def render(with_children = true)
          # Re-place against the combo's final geometry now that the cascade has
          # run: re-fits height and re-decides below-vs-above, clamped to the
          # window (see `ComboBox#place_popup`). Doing this on every render (not
          # only at open) catches a themed border or relayout that moved the
          # combo. Falls back to a local height-only refit if no owning combo.
          if c = combo
            c.place_popup self
          else
            h = @visible_rows + ivertical
            self.height = h unless height == h
          end
          super
        end
      end

      getter options : Array(String)

      # Index of the current option. Assigning clamps to the option list and
      # routes through the same path a user's choice takes, so `#value`, the edit
      # buffer, the filtered popup and the rendered content all follow and
      # `Event::CurrentChanged` fires. It used to be a bare `property`, whose
      # generated setter — the obvious `setCurrentIndex` — did none of that and
      # left the box internally inconsistent, disagreeing with its own
      # `ComboBox::Popup` (which gets the real thing from `Mixin::ItemView`).
      getter selected : Int32 = 0

      # :ditto:
      def selected=(index : Int) : Nil
        return if @options.empty?
        i = index.clamp(0, @options.size - 1)
        set_value @options[i], i
      end

      # Qt spelling of `#selected` / `#selected=` (`QComboBox#currentIndex`),
      # matching `Mixin::ItemView`. Preferred in new code.
      def current_index : Int32
        @selected
      end

      # :ditto:
      def current_index=(index : Int) : Nil
        self.selected = index
      end

      # Tag-stripped text of the current selection (or the typed text, when
      # `#editable?` and it doesn't match an option).
      getter value : String = ""

      # Qt spelling of `#value` (`QComboBox#currentText`).
      def current_text : String
        @value
      end

      # Selects the option whose text is *text* (Qt's `setCurrentText`). With no
      # such option, an `#editable?` box takes *text* as its free-text value —
      # exactly as if it had been typed and committed — and a non-editable one is
      # left alone, since it has no way to show a value that isn't an option.
      def current_text=(text : String) : Nil
        if i = @options.index text
          set_value text, i
        elsif editable?
          set_value text
        end
      end

      # Whether the box accepts free-text entry that filters the options
      # (Qt's `QComboBox#editable`).
      property? editable : Bool = false

      # Maximum number of rows shown in the popup before it scrolls (Qt's
      # `QComboBox#maxVisibleItems`).
      property max_visible_items : Int32 = 6

      # Editable-mode text buffer.
      @text : String = ""
      # Options currently shown in the popup (the filtered subset in editable
      # mode; all of them otherwise).
      @filtered : Array(String) = [] of String

      @popup : Popup?

      def initialize(options : Enumerable(String) = [] of String, selected = 0, editable = false, **input)
        @options = options.to_a
        @editable = editable

        super **input

        @selected = @options.empty? ? 0 : selected.clamp(0, @options.size - 1)
        @value = @options[@selected]? || ""
        # Edit buffer starts empty; committed `@value` is shown until the user
        # types (see `#update_content`).
        @text = ""
        @filtered = @options.dup

        handle Crysterm::Event::KeyPress
        handle Crysterm::Event::Click

        # Mouse wheel cycles the value while closed; while open it scrolls the
        # drop-down (via `Popup#wheel_scroll`, keeping the selection under the
        # pointer) rather than dragging the highlight like an arrow key.
        on(Crysterm::Event::Mouse) do |e|
          if e.action.wheel_down?
            @open ? @popup.try(&.wheel_scroll(1)) : cycle(1)
            e.accept
            request_render
          elsif e.action.wheel_up?
            @open ? @popup.try(&.wheel_scroll(-1)) : cycle(-1)
            e.accept
            request_render
          end
        end

        # An editable combo keeps focus while open (so typing keeps filtering);
        # if focus leaves via Tab, nothing else would close the popup, so tidy up
        # on blur to avoid an orphaned popup or window-level mouse handler.
        #
        # Focus moving *into* our own drop-down must NOT dismiss it: the window
        # implicitly focuses the scrollable list under the pointer on a wheel
        # (`Window#dispatch_mouse` -> `focusable_at`), which would otherwise close
        # the popup mid-scroll. Only a blur to something outside combo+popup closes.
        on(Crysterm::Event::Blur) do |e|
          next unless editable? && @open
          nf = e.el
          next if nf && (p = @popup) && (nf == p || nf.descendant_of?(p))
          # `refocus: false`: this runs mid-`_focus` (focus is on its way to
          # `e.el`); a `focus` here would re-enter the focus machinery, land
          # focus back on the combo (Tab needed twice) and corrupt the focus
          # history with a duplicate entry.
          close refocus: false
        end

        update_content
      end

      # The drop-down list (for `Mixin::Popup`).
      def popup_widget : ::Crysterm::Widget?
        @popup
      end

      private def printable?(ch : Char) : Bool
        o = ch.ord
        o >= 32 && o != 127
      end

      # The resolved drop-down arrow: CSS `ComboBox::drop-down { glyph: … }`,
      # then the registry; `nil` when the stylesheet says `glyph: none` (no
      # arrow is drawn, and its space collapses).
      private def dropdown_arrow : Char?
        glyph?(Glyphs::Role::DropdownArrow, style.raw_sub_style("drop-down"))
      end

      # The arrow baked into the current content, so `#render` can notice a
      # restyle (CSS `glyph`, `Glyphs.set`, a tier switch) and refresh.
      @_arrow : Char? = nil

      private def update_content
        # While editing, show the typed buffer; otherwise show the committed value.
        shown = editable? ? (@text.empty? ? @value : @text) : @value
        arrow = @_arrow = dropdown_arrow
        suffix = arrow ? " #{arrow}" : ""
        if shown.empty? && @options.empty? && !editable?
          set_content suffix
        else
          set_content "#{shown}#{suffix}"
        end
      end

      # Refreshes the content when the resolved arrow changed out from under
      # it (see `@_arrow`); a no-op on the steady-state frame.
      def render(with_children = true)
        update_content if @_arrow != dropdown_arrow
        super
      end

      # Recomputes the popup's option subset: a case-insensitive substring filter
      # on the typed text in editable mode, all options otherwise.
      private def refilter
        @filtered =
          if editable? && !@text.empty?
            q = @text.downcase
            @options.select(&.downcase.includes?(q))
          else
            @options.dup
          end
      end

      # Replaces the list of choices, keeping the selection in range.
      def options=(opts : Enumerable(String))
        was = current_state
        @options = opts.to_a
        @selected = @selected.clamp(0, Math.max(0, @options.size - 1))
        @value = @options[@selected]? || ""
        refresh_options was
      end

      # Number of options (Qt's `QComboBox#count`).
      def count : Int32
        @options.size
      end

      # The text of the option at *index*, or `nil` when out of range (Qt's
      # `itemText`).
      def item_text(index : Int) : String?
        # Guard the negative index explicitly: Crystal's `[]?` counts a negative
        # from the end, so `item_text(-1)` would answer with the *last* option.
        return nil if index < 0
        @options[index]?
      end

      # Appends an option (Qt's `addItem`). Returns its index.
      def add_item(text : String) : Int32
        insert_item @options.size, text
      end

      # Inserts an option at *index* (clamped to the end), like Qt's
      # `insertItem`; returns the index it landed at. The current option stays
      # current, following its shift.
      def insert_item(index : Int, text : String) : Int32
        was = current_state
        i = index.clamp(0, @options.size)
        @options.insert i, text
        if @options.size == 1
          # First option to arrive: nothing was selectable before, so it becomes
          # the value (matching `#initialize`, which starts an empty combo at 0).
          @selected = 0
          @value = text
        elsif i <= @selected
          # Inserted at or before the current option, which therefore shifted
          # right — follow it, rather than leave the index on its new neighbor.
          @selected += 1
        end
        refresh_options was
        i
      end

      # Removes the option at *index* (Qt's `removeItem`); out of range is a
      # no-op. Returns the removed text.
      def remove_item(index : Int) : String?
        return nil unless 0 <= index < @options.size
        was = current_state
        i = index.to_i
        text = @options.delete_at i
        # Mirror of `#insert_item`: removing *before* the current option shifts
        # it left. Removing the current one itself leaves the index on its
        # successor (Qt's behavior), and the clamp catches removing the last.
        @selected -= 1 if i < @selected
        @selected = @selected.clamp(0, Math.max(0, @options.size - 1))
        # An editable box may be showing free text that was never an option;
        # emptying the list must not silently blank it.
        @value = @options[@selected]? || (editable? ? @value : "")
        refresh_options was
        text
      end

      # Drops every option (Qt's `clear`).
      def clear : Nil
        was = current_state
        @options.clear
        @selected = 0
        @value = ""
        refresh_options was
      end

      # The `{index, value}` pair a list mutation might move, sampled before it
      # runs so `#refresh_options` can tell whether to report a change.
      private def current_state : Tuple(Int32, String)
        {@selected, @value}
      end

      # Shared tail of every option-list mutation: re-filters, re-fits an open
      # drop-down, refreshes the rendered value, and reports
      # `Event::CurrentChanged` if the mutation moved the selection off *was*
      # (inserting ahead of it, removing it, truncating the list, …).
      #
      # An open drop-down must be re-fitted to the new options, or a click on a
      # visible row resolves against the new `@filtered` and commits a value the
      # user never saw (or silently no-ops when there are fewer options than
      # rows). `#refresh_popup` guards on `@open` and re-runs `position_popup`.
      private def refresh_options(was : Tuple(Int32, String)) : Nil
        # Keep edit buffer empty so the box shows the committed value (matches `#set_value`).
        @text = ""
        refilter
        refresh_popup
        update_content
        request_render
        emit Crysterm::Event::CurrentChanged, @selected if was != current_state
      end

      # Drops the popup open. In editable mode the combo keeps focus (so typing
      # keeps filtering); otherwise focus moves into the popup for navigation.
      # (Grab, outside-click dismissal, and the open flag come from `Mixin::Popup`.)
      def open
        return if @open
        return if !editable? && @options.empty?
        pop = ensure_popup
        # An editable combo keeps keyboard focus; the popup is driven indirectly
        # (`@popup.down`/`up`) and must stay off the wheel-implicit-focus path
        # (`Window#focusable_at`), else wheeling over the open list focuses the
        # list, blurs the combo, and dismisses the drop-down. A non-editable
        # combo navigates the popup directly, so it keeps it focusable.
        pop.focus_on_click = !editable?
        refilter
        pop.items = @filtered
        # Highlight lands on current selection; editable mode starts at top
        # since the popup is a freshly filtered list.
        pop.selected = editable? ? 0 : @selected.clamp(0, Math.max(0, @filtered.size - 1))
        position_popup pop
        show_popup pop, focus_popup: !editable?
      end

      # Closes the popup (without changing the value) and refocuses the combo.
      # Pass `refocus: false` when closing because focus is already moving
      # elsewhere (the Blur handlers) — refocusing mid-blur would re-enter the
      # focus machinery and bounce focus back onto the combo.
      def close(refocus : Bool = true)
        return unless teardown_popup
        # End editing session: drop filter buffer so the box shows committed value.
        if editable?
          @text = ""
          update_content
        end
        focus if refocus
      end

      # `#toggle` (open/close) comes from `Mixin::Popup`.

      # Commits the choice at *index* into the currently-shown (`@filtered`) list:
      # updates the value, closes the popup, and emits `Event::Action` — the
      # *activation* signal (Qt's `activated`), which fires for the user's pick
      # even when it re-picks the value already current. A real value change also
      # emits `Event::CurrentChanged` from `#set_value`.
      def commit(index : Int)
        # An out-of-range row commits nothing, so it activates nothing either —
        # it only dismisses the drop-down.
        return close unless v = @filtered[index]?
        # Non-editable: `@filtered` is `@options` itself, so the index maps
        # directly — pass it through so a repeated option label commits the
        # row actually picked (see `#set_value`). Editable: popup is a
        # filtered subset whose index doesn't map to `@options`; fall back to
        # value lookup.
        set_value v, editable? ? nil : index.to_i
        close
        emit Crysterm::Event::Action, @value
      end

      # Commits the free-text buffer (editable mode, no matching option).
      def commit_text
        set_value @text
        close
        emit Crysterm::Event::Action, @value
      end

      # Sets the displayed value, recording which option index it corresponds to,
      # and emits `Event::CurrentChanged` when either actually moved. When the
      # caller knows the authoritative index (cycling, or a click on a specific
      # row), pass it as *index* so selection lands on the row actually chosen.
      # Otherwise looked up by value, which with duplicate labels would resolve to
      # the first match. Falls back to the current selection if no index given.
      #
      # Every write to `@value`/`@selected` goes through here, so nothing can
      # leave the two — or the rendered content — out of step.
      private def set_value(v : String, index : Int32? = nil)
        i = index || @options.index(v) || @selected
        changed = @value != v || @selected != i
        @value = v
        # Clear edit buffer so display reverts to the committed value.
        @text = ""
        @selected = i
        update_content
        emit Crysterm::Event::CurrentChanged, @selected if changed
      end

      # Restores the initial state: selects the first option (empty when there
      # are none) and clears any typed edit buffer. Used by `Form#reset`.
      # Programmatic, so it reports `Event::CurrentChanged` but not the
      # user-activation `Event::Action`.
      def reset
        set_value @options.first? || "", 0
        request_render
      end

      # Cycles the selection by *delta* without opening the popup (Qt changes the
      # current item with the arrow keys on a closed, non-editable combo, and
      # counts that as an activation).
      def cycle(delta : Int)
        return if @options.empty?
        n = @options.size
        # Crystal's `%` with a positive divisor is always non-negative, so this
        # wraps a negative delta correctly with no extra guard.
        i = (@selected + delta) % n
        # Pass the computed index as authoritative: `#set_value`'s value-based
        # lookup would resolve a repeated label to its first occurrence,
        # preventing cycling onto a later duplicate.
        set_value @options[i], i
        emit Crysterm::Event::Action, @value
        request_render
      end

      private def ensure_popup : Popup
        # A cross-window reparent strands the cached popup on the old window
        # (it is a *window* child, not ours): reopening would render the list
        # over there while placement and the dismiss grab use the new window.
        # Drop the stale popup and rebuild on the current window.
        if (stale = @popup) && stale.window? != window?
          ::Crysterm::Widget.destroy_satellite stale
          @popup = nil
        end
        @popup ||= begin
          pop = Popup.new(
            window: window,
            top: 0, left: 0,
            width: 12, height: 3,
          )
          pop.add_css_class "popup" # themed via `.popup { border: solid; ... }`
          pop.combo = self
          # A non-editable combo focuses the popup; when focus then leaves the
          # combo+popup pair (e.g. Tab out of the open list), nothing else
          # would dismiss it — it stayed open with a live modal grab until an
          # outside click. `refocus: false`: focus is already moving on.
          pop.on(Crysterm::Event::Blur) do |e|
            next unless @open
            nf = e.el
            next if nf && (nf == self || nf == pop || nf.descendant_of?(pop) || nf.descendant_of?(self))
            close refocus: false
          end
          window.append pop
          pop.hide
          pop
        end
      end

      # Refreshes the open popup's rows after the filter changes. Re-runs
      # `#position_popup` so the drop-down's height tracks the new match count
      # instead of keeping its original size.
      private def refresh_popup
        if @open && (pop = @popup)
          pop.items = @filtered
          pop.selected = 0
          position_popup pop
        end
      end

      private def position_popup(pop : Popup)
        rows = Math.min(Math.max(@filtered.size, 1), @max_visible_items)
        pop.visible_rows = rows
        # Full placement (size + below/above flip + clamp); re-run each render
        # once the cascade resolves the border (see `#place_popup` /
        # `Popup#render`).
        place_popup pop
      end

      # Places the drop-down against the combo: below when its full height fits,
      # otherwise flipped above (Qt opens upward when the list would run off the
      # bottom), clamped on-window. Without it the list spilled past the last
      # row and looked like it never opened.
      #
      # Outer height = visible rows plus the popup's own border/padding
      # (`#ivertical`), so themed borders size correctly; width tracks the combo.
      # `Overlay.place_child` owns the below/above fit choice, the on-window
      # clamp, and the single absolute→window-local inset conversion (a
      # window-appended popup's `left`/`top` are relative to the window content
      # origin). Called at open and from `Popup#render`; guarded assignments make
      # it a steady-state no-op.
      def place_popup(pop : Popup) : Nil
        want = pop.visible_rows + pop.ivertical
        pop.height = want unless pop.height == want
        w = Math.max(awidth, 4)
        pop.width = w unless pop.width == w
        Overlay.place_child(pop, {aleft, atop, awidth, aheight}, {w, want},
          Overlay::BELOW_ABOVE)
      rescue
        # Not laid out yet — keep defaults; `Popup#render` re-runs with real geometry.
      end

      def on_keypress(e)
        return on_keypress_editable(e) if editable?

        return if @open
        if e.key == Tput::Key::Down || e.key == Tput::Key::Enter || e.char == ' '
          open
          e.accept
        elsif e.key == Tput::Key::Up
          cycle -1
          e.accept
        end
      end

      # Opens the popup if closed, steps its highlight (block yields the live
      # popup so the caller picks `#down`/`#up`), then accepts *e* and repaints.
      private def step_open_popup(e, &)
        open unless @open
        @popup.try { |p| yield p }
        e.accept
        request_render
      end

      # Key handling for an editable combo: the box keeps focus and drives the
      # (filtering) popup itself.
      private def on_keypress_editable(e)
        k = e.key
        ch = e.char

        if k == Tput::Key::Enter
          if @open
            @filtered.empty? ? commit_text : commit(@popup.try(&.selected) || 0)
          else
            open
          end
          e.accept
        elsif k == Tput::Key::Escape
          close if @open
          e.accept
        elsif k == Tput::Key::Down
          step_open_popup(e, &.down)
        elsif k == Tput::Key::Up
          step_open_popup(e, &.up)
        elsif k == Tput::Key::Backspace || k == Tput::Key::CtrlH
          unless @text.empty?
            @text = @text[0...-1]
            refilter
            refresh_popup
            update_content
            request_render
          end
          e.accept
        elsif ch && !k && printable?(ch)
          @text += ch
          refilter
          open unless @open
          refresh_popup
          update_content
          request_render
          e.accept
        end
      end

      def on_click(e)
        toggle
      end

      # The popup is a window child (to overlay outside the combo's own box), so
      # it isn't torn down with the combo automatically.
      def destroy
        teardown_popup_on_destroy
        @popup = nil
        super
      end
    end
  end
end
