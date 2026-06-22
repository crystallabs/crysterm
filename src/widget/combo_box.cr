require "./input"
require "./list"

module Crysterm
  class Widget
    # Drop-down selector, modeled after Qt's `QComboBox` (non-editable).
    #
    # Closed, it shows the current value followed by a `▾` marker. Opening it
    # (Enter / Space / Down / click) drops a `List` popup below the box; choosing
    # an item — with the keyboard or mouse — closes the popup and updates the
    # value, emitting `Event::Action` with the chosen text. While closed, Up/Down
    # cycle the value in place, like a `QComboBox`.
    #
    # The collection is called `#options` (not `items`, which `Widget` already
    # uses for child widgets).
    class ComboBox < Input
      # The popup `List`. It overrides `List`'s commit/cancel hooks so a choice
      # routes back to the owning combo rather than emitting list item events.
      class Popup < List
        property combo : ComboBox?

        def enter_selected
          combo.try &.commit selected
        end

        def cancel_selected
          combo.try &.dismiss
        end

        # A *single* click on any row commits it (a plain `List` would only
        # select on the first click and commit on the second). We add our own
        # click handler on top of the one `List#create_item` installs.
        def create_item(*args, **opts)
          item = super
          if mouse?
            item.on(::Crysterm::Event::Click) do
              if i = @items.index item
                combo.try &.commit i
              end
            end
          end
          item
        end
      end

      # `getter` (not `property`): the custom `options=` below clamps the
      # selection, and a generated setter would shadow it for `Array` arguments.
      getter options : Array(String)
      property selected : Int32 = 0

      # Tag-stripped text of the current selection.
      getter value : String = ""

      # Maximum number of rows shown in the popup before it scrolls.
      property max_visible : Int32 = 6

      @open = false
      @popup : Popup?
      # Screen-level handler (active only while open) that closes the popup when
      # the user clicks outside it.
      @ev_outside : Crysterm::Event::Mouse::Wrapper?

      def initialize(options : Enumerable(String) = [] of String, selected = 0, **input)
        @options = options.to_a

        super **input

        @selected = @options.empty? ? 0 : selected.clamp(0, @options.size - 1)
        @value = @options[@selected]? || ""

        handle Crysterm::Event::KeyPress
        handle Crysterm::Event::Click

        update_content
      end

      def open? : Bool
        @open
      end

      private def update_content
        set_content(@options.empty? ? " ▾" : "#{@value} ▾")
      end

      # Replaces the list of choices, keeping the selection in range.
      def options=(opts : Enumerable(String))
        @options = opts.to_a
        @selected = @selected.clamp(0, Math.max(0, @options.size - 1))
        @value = @options[@selected]? || ""
        update_content
        request_render
      end

      # Drops the popup open.
      def open
        return if @open || @options.empty?
        @open = true
        pop = ensure_popup
        pop.set_items @options
        pop.selekt @selected
        position_popup pop
        pop.show
        pop.front!
        pop.focus

        # Dismiss when the user clicks anywhere outside the popup (and outside the
        # combo itself, whose own click toggles).
        @ev_outside = screen.on(Crysterm::Event::Mouse) do |e|
          if e.action.down? && (p = @popup)
            dismiss unless point_in?(p, e.x, e.y) || point_in?(self, e.x, e.y)
          end
        end

        request_render
      end

      # Closes the popup (without changing the value) and refocuses the combo.
      def close
        return unless @open
        @open = false
        @ev_outside.try { |w| screen?.try &.off Crysterm::Event::Mouse, w }
        @ev_outside = nil
        @popup.try &.hide
        focus
        request_render
      end

      # Whether the absolute point (*x*, *y*) lies within *widget*'s last
      # rendered box. False if the widget has not been laid out yet.
      private def point_in?(widget : Widget, x : Int32, y : Int32) : Bool
        l = widget.aleft
        t = widget.atop
        l <= x < l + widget.awidth && t <= y < t + widget.aheight
      rescue
        false
      end

      def toggle
        @open ? close : open
      end

      # Commits the choice at *index*: updates the value, closes the popup, and
      # emits `Event::Action`.
      def commit(index : Int)
        if 0 <= index < @options.size
          @selected = index.to_i
          @value = @options[index]
          update_content
          emit Crysterm::Event::Action, @value
        end
        close
      end

      # Closes the popup leaving the value unchanged.
      def dismiss
        close
      end

      # Cycles the selection by *delta* without opening the popup (Qt changes the
      # current item with the arrow keys on a closed combo).
      def cycle(delta : Int)
        return if @options.empty?
        n = @options.size
        @selected = (@selected + delta) % n
        @selected += n if @selected < 0
        @value = @options[@selected]
        update_content
        emit Crysterm::Event::Action, @value
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

      # Positions the popup directly below the combo, matching its width. Falls
      # back to the popup's defaults if the combo has not been laid out yet.
      private def position_popup(pop : Popup)
        begin
          lp = last_rendered_position
          pop.top = lp.yi + aheight
          pop.left = lp.xi
          pop.width = Math.max(awidth, 4)
        rescue
          # Not laid out yet — keep defaults.
        end
        rows = Math.min(@options.size, @max_visible)
        rows = 1 if rows < 1
        pop.height = rows + 2 # + border
      end

      def on_keypress(e)
        return if @open
        if e.key == Tput::Key::Down || e.key == Tput::Key::Enter || e.char == ' '
          open
          e.accept
        elsif e.key == Tput::Key::Up
          cycle -1
          e.accept
        end
      end

      def on_click(e)
        toggle
      end

      # The popup is a *screen* child (so it can overlay outside the combo's own
      # box), so it isn't torn down with the combo automatically — remove it, and
      # any active outside-click handler, here.
      def destroy
        @ev_outside.try { |w| screen?.try &.off Crysterm::Event::Mouse, w }
        @ev_outside = nil
        if pop = @popup
          # The popup is a top-level screen child (no widget parent), so
          # `remove_from_parent` can't detach it — remove it from the screen.
          screen?.try &.remove pop
          pop.destroy
        end
        @popup = nil
        super
      end
    end
  end
end
