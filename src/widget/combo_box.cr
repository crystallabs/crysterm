require "./input"
require "./abstract_item_view"
require "../mixin/item_view"
require "../mixin/popup"

module Crysterm
  class Widget
    # Drop-down selector, modeled after Qt's `QComboBox`.
    #
    # Closed, it shows the current value followed by a `▾` marker. Opening it
    # (Enter / Space / Down / click) drops a `List` popup below the box; choosing
    # an item — with the keyboard or mouse — closes the popup and updates the
    # value, emitting `Event::Action` with the chosen text. While closed, Up/Down
    # cycle the value in place.
    #
    # With `#editable?` the box also accepts free text: typing filters the popup
    # to the matching options (case-insensitive substring), Up/Down move the
    # highlight, and Enter commits the highlighted option — or the typed text
    # itself when nothing matches.
    #
    # The collection is called `#options` (not `items`, which `Widget` already
    # uses for child widgets).
    #
    # <!-- widget-examples:capture v1 -->
    # ![ComboBox screenshot](../../examples/widget/combo_box/combo_box-capture5s.apng)
    # <!-- /widget-examples:capture -->
    class ComboBox < Input
      # Pop-up lifecycle (open flag, modal grab, outside-click dismissal, grab
      # region, teardown). Provides `#open?`/`#show_popup`/`#teardown_popup`/
      # `#grab_contains?`; we supply `#popup_widget` and `#close`.
      include Mixin::Popup

      # A combo is a fixed-size control: it must honor its given `width` rather
      # than shrinking to the (short) `"value ▾"` content the way an `Input`
      # would — otherwise its clickable area collapses to a few cells.
      @resizable = false

      # The popup drop-down list. An `AbstractItemView` (a sibling of `List`,
      # reusing the row machinery via `Mixin::ItemView` — Qt uses an internal
      # `QListView` here). It overrides the item view's commit/cancel hooks so a
      # choice routes back to the owning combo rather than emitting list item events.
      class Popup < AbstractItemView
        include Mixin::ItemView

        # A single click on any row commits it.
        @activate_on_click = true

        # Moving the pointer onto a row highlights it — no click required — the
        # way a desktop combo drop-down (and the `Completer` popup) tracks the
        # mouse. The per-row `MouseOver` hook is wired by
        # `Mixin::ItemView#create_item` when this is on; keyboard navigation and
        # click-to-commit are unaffected.
        @hover_select = true

        # How many option rows the owning combo wants visible. The popup's outer
        # height is this plus the popup's *own* border/padding (`#iheight`), set
        # by `ComboBox#position_popup` and re-applied at render (see `#render`).
        property visible_rows : Int32 = 1

        # The drop-down is an overlay (Qt's `.popup`): at the unstyled floor it
        # carries a structural border so it separates from the content behind it.
        # A theme can override or remove it (see `Mixin::Style#floor_border?`).
        def floor_border? : Bool
          true
        end

        property combo : ComboBox?

        def enter_selected
          combo.try &.commit selected
        end

        def cancel_selected
          combo.try &.dismiss
        end

        # Re-fits the popup's outer height to `#visible_rows` plus its *own*
        # border/padding (`#iheight`) at render — now that the CSS cascade (which
        # decides the border) has run. `ComboBox#position_popup` sizes us up
        # front from `#iheight` too, but at that point a themed border may not yet
        # be resolved; this corrects it the same way `Widget::Menu#autosize`
        # re-fits a freshly-opened menu. No assumption of a 1-cell border: a
        # borderless (`iheight == 0`) or thicker/asymmetric frame all fit. The
        # `height=` is a no-op when unchanged, so this costs nothing in steady
        # state.
        def render(with_children = true)
          # Re-place us against the combo's *final* geometry now that the cascade
          # has run: this re-fits the height to `#visible_rows` plus the resolved
          # border (`#iheight`) AND re-decides below-vs-above and clamps us to the
          # window (see `ComboBox#place_popup`). Doing it here — not only at open —
          # means a themed border (sized after the open) or a relayout that moved
          # the combo can't leave us mis-sized or spilling off-window. Falls back
          # to the local height-only refit if we somehow have no owning combo.
          if c = combo
            c.place_popup self
          else
            h = @visible_rows + iheight
            self.height = h unless height == h
          end
          super
        end

        # Maps a hovered item index back to the entry actually under the pointer.
        # Item boxes are hit-tested by their *unscrolled* geometry (see
        # `Widget#atop`), so the index handed in is the pointer's visual row from
        # the top of the viewport, independent of scroll — and rows below the last
        # shown one still report a phantom index. Clamp the visual row to the
        # viewport (so a pointer past the bottom parks on the last shown row) and
        # add `#child_base`, mirroring `Completer::Popup#hover_item`. (For a short,
        # unscrolled drop-down `child_base` is 0 and this is just `selekt i`.)
        def hover_item(i : Int)
          visible = visible_content_rows
          visible = 1 if visible < 1
          row = i.clamp(0, visible - 1)
          selekt (@child_base + row).clamp(0, @items.size - 1)
        end
      end

      getter options : Array(String)
      property selected : Int32 = 0

      # Tag-stripped text of the current selection (or the typed text, when
      # `#editable?` and it doesn't match an option).
      getter value : String = ""

      # Whether the box accepts free-text entry that filters the options
      # (Qt's `QComboBox#editable`).
      property? editable : Bool = false

      # Maximum number of rows shown in the popup before it scrolls.
      property max_visible : Int32 = 6

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
        # The edit buffer starts empty (each editing session begins fresh); the
        # committed `@value` is shown until the user types (see `#update_content`).
        @text = ""
        @filtered = @options.dup

        handle Crysterm::Event::KeyPress
        handle Crysterm::Event::Click

        # Mouse wheel selects the next/previous entry (cycles the value while
        # closed; moves the popup highlight while open), like a GUI combo box.
        on(Crysterm::Event::Mouse) do |e|
          if e.action.wheel_down?
            @open ? @popup.try(&.down) : cycle(1)
            e.accept
            request_render
          elsif e.action.wheel_up?
            @open ? @popup.try(&.up) : cycle(-1)
            e.accept
            request_render
          end
        end

        # An editable combo keeps focus while open (so typing keeps filtering), so
        # if focus leaves it — e.g. via Tab — nothing else would close the popup.
        # Tidy up on blur so no orphaned popup or window-level mouse handler is
        # left behind (which otherwise corrupts later input handling).
        #
        # But focus merely moving *into* our own drop-down must NOT dismiss it: the
        # window implicitly focuses the scrollable list under the pointer on a wheel
        # (`Window#dispatch_mouse` → `focusable_at`), and that blur would otherwise
        # close the popup mid-scroll. Only a blur to something *outside* the
        # combo+popup (Tab away, a click elsewhere) closes. (The popup is also kept
        # off the wheel-focus path entirely for editable combos — see `#open` — so
        # this is belt-and-suspenders for any other focus-into-popup route.)
        on(Crysterm::Event::Blur) do |e|
          next unless editable? && @open
          nf = e.el
          next if nf && (p = @popup) && (nf == p || nf.has_ancestor?(p))
          close
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

      private def update_content
        # While editing, show the typed buffer; otherwise (and when the buffer is
        # empty) show the committed value.
        shown = editable? ? (@text.empty? ? @value : @text) : @value
        if shown.empty? && @options.empty? && !editable?
          set_content " ▾"
        else
          set_content "#{shown} ▾"
        end
      end

      # Recomputes the popup's option subset: a case-insensitive substring filter
      # on the typed text in editable mode, all options otherwise.
      private def refilter
        @filtered =
          if editable? && !@text.empty?
            @options.select(&.downcase.includes?(@text.downcase))
          else
            @options.dup
          end
      end

      # Replaces the list of choices, keeping the selection in range.
      def options=(opts : Enumerable(String))
        @options = opts.to_a
        @selected = @selected.clamp(0, Math.max(0, @options.size - 1))
        @value = @options[@selected]? || ""
        # Keep the edit buffer empty so the box shows the committed value (and the
        # popup isn't pre-filtered) — matching `#set_value`.
        @text = ""
        refilter
        update_content
        request_render
      end

      # Drops the popup open. In editable mode the combo keeps focus (so typing
      # keeps filtering); otherwise focus moves into the popup for navigation.
      # (Grab, outside-click dismissal, and the open flag come from `Mixin::Popup`.)
      def open
        return if @open
        return if !editable? && @options.empty?
        pop = ensure_popup
        # An editable combo keeps keyboard focus (so typing keeps filtering); the
        # popup is driven indirectly (`@popup.down`/`up`). It must therefore stay
        # *off* the wheel-implicit-focus path (`Window#focusable_at`), otherwise
        # wheeling over the open list focuses the list, blurs the combo, and the
        # blur dismisses the drop-down. A non-editable combo navigates the popup
        # directly, so it keeps the popup focusable.
        pop.focus_on_click = !editable?
        refilter
        pop.set_items @filtered
        # Land the highlight on the current selection (Qt opens a combo with the
        # current item highlighted). In editable mode the popup is a freshly
        # filtered list, so start at the top.
        pop.selekt(editable? ? 0 : @selected.clamp(0, Math.max(0, @filtered.size - 1)))
        position_popup pop
        show_popup pop, focus_popup: !editable?
      end

      # Closes the popup (without changing the value) and refocuses the combo.
      def close
        return unless teardown_popup
        # End the editing session: drop the filter buffer so the box shows the
        # committed value again.
        if editable?
          @text = ""
          update_content
        end
        focus
      end

      def toggle
        @open ? close : open
      end

      # Commits the choice at *index* into the currently-shown (`@filtered`) list:
      # updates the value, closes the popup, and emits `Event::Action`.
      def commit(index : Int)
        if v = @filtered[index]?
          # For a non-editable combo `@filtered` is `@options` itself (unfiltered),
          # so the chosen row's index *is* its index in `@options`; pass it through
          # so a repeated option label commits the row actually picked rather than
          # an identical earlier one (see `#set_value`). In editable mode the popup
          # is a filtered subset, so its index doesn't map to `@options` — fall back
          # to the value lookup there.
          set_value v, editable? ? nil : index.to_i
        end
        close
      end

      # Commits the free-text buffer (editable mode, no matching option).
      def commit_text
        set_value @text
        close
      end

      # Sets the displayed value, recording which option index it corresponds to.
      # When the caller already knows the authoritative index (cycling, or a click
      # on a specific row), it is passed in *index* so the selection lands on the
      # row actually chosen. Otherwise the index is looked up by value — which,
      # with duplicate option labels, would resolve to the *first* matching index
      # and snap the selection back onto an identical earlier entry (leaving later
      # duplicates unreachable). Falls back to the value lookup, then the current
      # selection, when no index is given.
      private def set_value(v : String, index : Int32? = nil)
        @value = v
        # Clear the edit buffer so the display reverts to showing the committed
        # value (not the leftover filter text).
        @text = ""
        @selected = index || @options.index(v) || @selected
        update_content
        emit Crysterm::Event::Action, @value
      end

      # Closes the popup leaving the value unchanged.
      def dismiss
        close
      end

      # Cycles the selection by *delta* without opening the popup (Qt changes the
      # current item with the arrow keys on a closed, non-editable combo).
      def cycle(delta : Int)
        return if @options.empty?
        n = @options.size
        @selected = (@selected + delta) % n
        @selected += n if @selected < 0
        # Pass the freshly-computed index as authoritative: `#set_value`'s
        # value-based lookup would otherwise resolve a repeated option label back
        # to its first occurrence, so cycling could never advance onto a later
        # duplicate (it would bounce off its earlier twin).
        set_value @options[@selected], @selected
        request_render
      end

      private def ensure_popup : Popup
        @popup ||= begin
          pop = Popup.new(
            window: window,
            top: 0, left: 0,
            width: 12, height: 3,
          )
          pop.add_css_class "popup" # themed via `.popup { border: solid; ... }`
          pop.combo = self
          window.append pop
          pop.hide
          pop
        end
      end

      # Refreshes the open popup's rows after the filter changes. Re-runs
      # `#position_popup` so the drop-down's height tracks the (now narrower or
      # wider) match count — otherwise it keeps the size it had when first opened,
      # leaving blank rows once the filter narrows, or scrolling a too-short popup
      # once it widens (e.g. after a Backspace), instead of fitting the matches.
      private def refresh_popup
        if @open && (pop = @popup)
          pop.set_items @filtered
          pop.selekt 0
          position_popup pop
        end
      end

      private def position_popup(pop : Popup)
        # Horizontal placement (set once): use the combo's *current* absolute box
        # (not the cached last-rendered position, which can be stale after a
        # relayout) so the dropdown lands aligned to the combo wherever it nests.
        begin
          pop.left = aleft
          pop.width = Math.max(awidth, 4)
        rescue
          # Not laid out yet — keep defaults.
          return
        end
        rows = Math.min(Math.max(@filtered.size, 1), @max_visible)
        pop.visible_rows = rows
        # Vertical placement (below/above + clamp); re-run each render once the
        # cascade resolves the border (see `#place_popup` / `Popup#render`).
        place_popup pop
      end

      # Places the drop-down *vertically*: directly below the combo when its full
      # height fits there, otherwise *flipped above* it. Qt opens a `QComboBox`
      # upward when the list would run off the bottom of the window (a combo low
      # on window — e.g. pushed down by a theme's group-box/title chrome). Without
      # this the list spilled past the last row and looked like it never opened.
      #
      # Outer height = the visible rows plus the popup's *own* border/padding,
      # derived from `#iheight` (the way `Widget::Menu` sizes from `iheight`)
      # rather than a hardcoded `+ 2`: a themed border (none, or thicker/
      # asymmetric) sizes correctly too. The height is capped to the room on the
      # chosen side so it never starts past the window edge — the list is
      # scrollable, so a tight fit just scrolls. Called both at open and from
      # `Popup#render`; guarded assignments make it a no-op in the steady state.
      def place_popup(pop : Popup) : Nil
        # Outer height = the visible rows plus the popup's *own* border/padding,
        # derived from `#iheight` (the way `Widget::Menu` sizes from `iheight`)
        # rather than a hardcoded `+ 2`: a borderless or thicker/asymmetric themed
        # border sizes correctly too. Always the full height — the list is
        # scrollable, so the only placement choice is *where* it drops, not how
        # tall it is. `Popup#render` re-applies this once the cascade resolves the
        # border.
        want = pop.visible_rows + pop.iheight
        pop.height = want unless pop.height == want

        # Vertical drop direction. By default below the combo (`atop + aheight`).
        # But flip the list *above* when it would otherwise run off the bottom of
        # the window and there's room above — Qt opens a `QComboBox` upward near
        # the window's last row (e.g. a combo pushed low by a theme's group-box /
        # title chrome). Without this the list spilled past the bottom edge and
        # looked like it never opened. Guarded on `aheight < sh` so a not-yet
        # laid-out combo (which reports the *full* window height until its first
        # render) never trips the flip; `Popup#render` re-runs us with real
        # geometry, so the final placement is always correct.
        sh = window.aheight
        below = atop + aheight
        top =
          if aheight < sh && below + want > sh && atop >= want
            atop - want # flip above (fully on-window, since atop >= want)
          else
            below
          end
        pop.top = top unless pop.top == top
      rescue
        # Not laid out yet — keep defaults.
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

      # Opens the popup if closed, steps its highlight (the block yields the live
      # popup so the caller picks `#down`/`#up`), then accepts *e* and repaints.
      # Shared by the editable combo's Down and Up keys.
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

      # The popup is a *window* child (so it can overlay outside the combo's own
      # box), so it isn't torn down with the combo automatically.
      def destroy
        teardown_popup_on_destroy
        @popup = nil
        super
      end
    end
  end
end
