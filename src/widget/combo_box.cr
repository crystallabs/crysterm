require "./input"
require "./list"
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
    class ComboBox < Input
      # Pop-up lifecycle (open flag, modal grab, outside-click dismissal, grab
      # region, teardown). Provides `#open?`/`#show_popup`/`#teardown_popup`/
      # `#grab_contains?`; we supply `#popup_widget` and `#close`.
      include Mixin::Popup

      # A combo is a fixed-size control: it must honor its given `width` rather
      # than shrinking to the (short) `"value ▾"` content the way an `Input`
      # would — otherwise its clickable area collapses to a few cells.
      @resizable = false

      # The popup `List`. It overrides `List`'s commit/cancel hooks so a choice
      # routes back to the owning combo rather than emitting list item events.
      class Popup < List
        # A single click on any row commits it.
        @activate_on_click = true

        property combo : ComboBox?

        def enter_selected
          combo.try &.commit selected
        end

        def cancel_selected
          combo.try &.dismiss
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
        # Tidy up on blur so no orphaned popup or screen-level mouse handler is
        # left behind (which otherwise corrupts later input handling).
        on(Crysterm::Event::Blur) { close if editable? && @open }

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
            @options.select { |o| o.downcase.includes? @text.downcase }
          else
            @options.dup
          end
      end

      # Replaces the list of choices, keeping the selection in range.
      def options=(opts : Enumerable(String))
        @options = opts.to_a
        @selected = @selected.clamp(0, Math.max(0, @options.size - 1))
        @value = @options[@selected]? || ""
        @text = @value
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
        refilter
        pop.set_items @filtered
        pop.selekt 0
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
          set_value v
        end
        close
      end

      # Commits the free-text buffer (editable mode, no matching option).
      def commit_text
        set_value @text
        close
      end

      private def set_value(v : String)
        @value = v
        # Clear the edit buffer so the display reverts to showing the committed
        # value (not the leftover filter text).
        @text = ""
        @selected = @options.index(v) || @selected
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
        set_value @options[@selected]
        request_render
      end

      private def ensure_popup : Popup
        @popup ||= begin
          pop = Popup.new(
            screen: screen,
            top: 0, left: 0,
            width: 12, height: 3,
            style: Style.new(border: true),
          )
          pop.combo = self
          screen.append pop
          pop.hide
          pop
        end
      end

      # Refreshes the open popup's rows after the filter changes.
      private def refresh_popup
        if @open && (pop = @popup)
          pop.set_items @filtered
          pop.selekt 0
        end
      end

      private def position_popup(pop : Popup)
        # Use the combo's *current* absolute box (not the cached last-rendered
        # position, which can be stale after a relayout) so the dropdown always
        # lands directly beneath the combo wherever it is nested.
        begin
          pop.top = atop + aheight
          pop.left = aleft
          pop.width = Math.max(awidth, 4)
        rescue
          # Not laid out yet — keep defaults.
        end
        rows = Math.min(Math.max(@filtered.size, 1), @max_visible)
        pop.height = rows + 2 # + border
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
          open unless @open
          @popup.try &.down
          e.accept
          request_render
        elsif k == Tput::Key::Up
          open unless @open
          @popup.try &.up
          e.accept
          request_render
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

      # The popup is a *screen* child (so it can overlay outside the combo's own
      # box), so it isn't torn down with the combo automatically.
      def destroy
        teardown_popup_on_destroy
        @popup = nil
        super
      end
    end
  end
end
