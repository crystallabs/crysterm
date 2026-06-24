require "./button"
require "./menu"

module Crysterm
  class Widget
    # Compact action button, modeled after Qt's `QToolButton`.
    #
    # Like `Button` it activates on Space/Enter or a click, but it adds the two
    # features that set a tool button apart from a plain push button:
    #
    # * **A default `Action`** (`#action=`, Qt's `setDefaultAction`). When set,
    #   the button shows the action's text and, on activation, triggers the
    #   action (emitting its `Event::Triggered`) in addition to its own
    #   `Event::Press`. The same `Action` can then drive a menu entry and a
    #   toolbar button at once, keeping them in sync. A disabled action is not
    #   triggered.
    #
    # * **A popup `Menu`** (`#menu=`, Qt's `setMenu`). How it opens depends on
    #   `#popup_mode`:
    #     - `InstantPopup`    — activating opens the menu (no press is emitted).
    #     - `MenuButtonPopup` — activating triggers the action/press as usual; the
    #       menu opens with the Down key (the `▾` indicator hints at it). This is
    #       the default.
    #     - `DelayedPopup`    — treated like `MenuButtonPopup`, since a terminal
    #       has no press-and-hold gesture.
    #
    # `#auto_raise?` mirrors Qt's flat-until-hovered appearance; it is stored and
    # exposed (e.g. for CSS/styling) — the default drawing is inherited from
    # `Button`.
    #
    # <!-- widget-examples:capture v1 -->
    # ![ToolButton screenshot](../../examples/widget/tool_button/tool_button-capture5s.apng)
    # <!-- /widget-examples:capture -->
    class ToolButton < Button
      # How a `#menu` is summoned (see the class docs).
      enum PopupMode
        DelayedPopup
        MenuButtonPopup
        InstantPopup
      end

      # The popup behaviour for this button's `#menu`.
      property popup_mode : PopupMode = PopupMode::MenuButtonPopup

      # Flat appearance until focused/hovered (Qt's `QToolButton#autoRaise`).
      property? auto_raise : Bool = false

      @action : Action?
      @menu : Menu?
      # Wheel-cycling position over the menu's activatable actions.
      @menu_index : Int32 = 0

      def initialize(
        action : Action? = nil,
        menu : Menu? = nil,
        auto_raise : Bool = false,
        popup_mode : PopupMode = PopupMode::MenuButtonPopup,
        **button,
      )
        super **button

        @auto_raise = auto_raise
        @popup_mode = popup_mode
        # Assign through the setters (after `super`, so `set_content` works) to
        # pick up the label mirroring and the `▾` indicator.
        menu.try { |m| self.menu = m }
        action.try { |a| self.action = a }

        # The mouse wheel cycles through the menu's actions, triggering each in
        # turn (handy on a tool button that stands in for a small set of choices).
        on(Crysterm::Event::Mouse) do |e|
          next unless m = @menu
          if e.action.wheel_down?
            cycle_menu m, 1
            e.accept
          elsif e.action.wheel_up?
            cycle_menu m, -1
            e.accept
          end
        end
      end

      # The default action, or `nil`.
      def action : Action?
        @action
      end

      # Sets (or clears) the default action, mirroring its text onto the button.
      def action=(a : Action?) : Action?
        # Idempotent: re-assigning the same action re-stamps identical content
        # and requests a needless repaint, so skip it (the guard only matters
        # because a render follows).
        return a if a == @action
        @action = a
        if a && !a.text.empty?
          set_content with_indicator(a.text)
          request_render
        end
        a
      end

      # The popup menu, or `nil`.
      def menu : Menu?
        @menu
      end

      # Attaches (or clears) the popup menu, refreshing the `▾` indicator.
      def menu=(m : Menu?) : Menu?
        # Idempotent: same menu → same indicator → no repaint needed.
        return m if m == @menu
        @menu = m
        # Re-stamp the current label so the indicator is added/removed.
        set_content with_indicator(base_label)
        request_render
        m
      end

      # Opens the popup menu directly below the button (no-op without a menu or
      # while not laid out on a screen).
      def show_menu : Nil
        m = @menu
        return unless m
        return unless screen?
        m.popup aleft, atop + aheight
      end

      def press
        # InstantPopup: the whole button is the menu drop-down — open it instead
        # of emitting a press / triggering the action.
        if @menu && @popup_mode.instant_popup?
          focus
          show_menu
          return
        end

        super # focus, emit Press, toggle if checkable

        # Fire the bound action too (Qt's default-action behaviour).
        @action.try do |a|
          a.activate if a.enabled
        end
      end

      # A click opens the popup menu (when one is attached); otherwise it presses
      # the button like a normal `Button`. (A terminal has no separate arrow
      # sub-region, so the whole button surface opens the menu — keyboard
      # Enter/Space still triggers the default action.)
      def on_click(e)
        if @menu
          focus
          show_menu
        else
          press
        end
      end

      def on_keypress(e)
        # Down summons the menu in the (default) MenuButtonPopup/DelayedPopup
        # modes, where activation is reserved for the action/press.
        if @menu && !@popup_mode.instant_popup? && e.key == Tput::Key::Down
          e.accept
          focus
          show_menu
          return
        end
        super
      end

      # Cycles the wheel position over the menu's activatable (non-separator,
      # enabled, non-submenu) actions and triggers the one landed on.
      private def cycle_menu(m : Menu, delta : Int32) : Nil
        acts = m.actions.select { |a| !a.separator? && a.enabled && !a.submenu? }
        return if acts.empty?
        @menu_index = (@menu_index + delta) % acts.size
        @menu_index += acts.size if @menu_index < 0
        acts[@menu_index].activate
      end

      # The label without the trailing indicator.
      private def base_label : String
        c = content
        c.ends_with?(" ▾") ? c[0...-2] : c
      end

      # Appends the `▾` popup indicator to *label* when a menu is attached.
      private def with_indicator(label : String) : String
        @menu ? "#{label} ▾" : label
      end
    end
  end
end
