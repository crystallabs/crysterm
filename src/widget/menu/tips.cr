module Crysterm
  class Widget
    class Menu
      # === Tips: status tips, tooltips and What's This ===
      #
      # What a menu says about its highlighted action, beyond the row itself.
      # Every change of the highlight — a hover, an arrow key, the first
      # reveal, a submenu opened by the keyboard with its first row selected
      # — is one `#highlight_changed`, which `#hover`s the action (its
      # `Event::Hovered`), emits `Event::ActionHovered` on the menu and every
      # menu above it (Qt's `QMenu::hovered(QAction*)` up the caused stack; a
      # `MenuBar` re-emits its menus' as `QMenuBar::hovered`), and then tells
      # of the action three ways:
      #
      # * The action's `Action#status_tip` goes out as `Event::StatusTip` on
      #   the chain's *root* menu (Qt's `QStatusTipEvent`, sent up to the
      #   menu's top-level widget), so a `MenuBar` hears every submenu's tip
      #   on the one menu it owns and a `MainWindow` shows it in the status
      #   bar; an empty text follows when the highlight leaves or the menu
      #   closes, so the bar is cleared.
      # * With `#tool_tips_visible?` on (Qt's `QMenu::toolTipsVisible`, off
      #   by default), the action's `Action#tool_tip` pops up in a
      #   `Widget::ToolTip` beside the row after the `tool_tip.delay` option's
      #   wake-up (Qt's `SH_ToolTip_WakeUpDelay`), placed as a submenu is —
      #   right of the menu, left when it does not fit — and inert: never
      #   focused or clicked, gone as soon as the highlight moves or leaves.
      #   A tooltip that only repeats the row's text is not shown.
      # * `F1` on a highlighted action with an `Action#whats_this` shows that
      #   text in the same popup at once (Qt's `F1` in a `QMenu`, which opens
      #   `QWhatsThis` on the action), until the highlight moves or the next
      #   key.
      #
      # Split out of `menu.cr` as `menu/popup.cr` and `menu/rows.cr` are.

      # Whether the highlighted action's tooltip pops up beside its row (Qt's
      # `QMenu::toolTipsVisible`). Unset (`nil`), a submenu follows its parent
      # menu, a torn-off menu the menu it was torn off while that lives
      # (`menu/tear_off.cr`), and a top-level menu the `menu.tool_tips` option,
      # which is off by default: Qt's menus show no tooltips unless asked, since
      # the status tip is the quieter place for a description.
      @tool_tips_visible : Bool?

      def tool_tips_visible? : Bool
        v = tool_tips_override
        v.nil? ? Config.menu_tool_tips : v
      end

      # The nearest explicit `#tool_tips_visible=` up the chain this menu
      # follows — its own, its parent menu's, its torn-off source's — or `nil`
      # for the option.
      protected def tool_tips_override : Bool?
        v = @tool_tips_visible
        return v unless v.nil?
        (parent_menu || @torn_source).try &.tool_tips_override
      end

      # Sets whether tooltips pop up, or `nil` to follow the parent menu and
      # the option again. Submenus are built fresh on each open and inherit
      # the setting, so one call on the top-level menu covers its chain.
      def tool_tips_visible=(value : Bool?) : Bool?
        @tool_tips_visible = value
        hide_tip_popup unless tool_tips_visible? || @whats_this_shown
        value
      end

      # The action last announced (`#highlight_changed`), so an unchanged
      # highlight — a re-selection of the same row — says nothing twice, and
      # a leaving highlight is known to have been there.
      @tip_action : Action?

      # The tooltip wake-up timer, while a highlighted action waits for its
      # tooltip; stopped when the highlight moves first.
      @tip_timer : Timer?

      # The popup the tooltip and the What's This text show in, created on
      # first use and destroyed with the menu. A satellite on the menu's
      # window, as `Widget#show_tool_tip`'s is.
      @tip_popup : ToolTip?

      # Whether the popup shows a What's This text, which no tooltip setting
      # takes down — only the highlight moving, a key, or the menu closing.
      @whats_this_shown = false

      # Takes stock after anything that may have moved or revealed the
      # highlight (`#current_index=`, the reveal in `#handle_key_press`), or
      # cleared it (`#cancel_current`): the action now highlighted — none
      # while the highlight is not shown, or on a separator — is announced if
      # it is not the one announced last.
      protected def highlight_changed : Nil
        act = (@show_highlight && visible?) ? selected_action : nil
        act = nil if act && act.separator?
        return if act.same?(@tip_action)
        @tip_action = act
        announce act
      end

      # The highlight is gone with the menu (its `Hide`): clears what the last
      # action put up. A menu that reopens starts with no highlight, so the
      # next hover announces afresh.
      protected def highlight_left : Nil
        hide_tip_popup
        return unless @tip_action
        @tip_action = nil
        announce nil
      end

      # Says the action highlighted — or, for `nil`, that none is — to the
      # action, this menu's listeners and the chain's root (the status tip),
      # and arms the tooltip.
      private def announce(act : Action?) : Nil
        hide_tip_popup
        if act
          # One tooltip at a time, as Qt's single `QToolTip`: a submenu's
          # row takes down the parent row's popup, and its pending wake-up.
          parent_menu.try &.hide_tip_popup
          act.hover
          relay_hovered act
          tip_root.emit ::Crysterm::Event::StatusTip, (act.status_tip || "")
          arm_tool_tip act
        else
          emit ::Crysterm::Event::ActionHovered, nil
          tip_root.emit ::Crysterm::Event::StatusTip, ""
        end
      end

      # Emits `Event::ActionHovered` for *act* on this menu and on every menu
      # above it — the parent menus up to the chain's root, then the root the
      # chain was torn off while it lives — as Qt fires `QMenu::hovered` on each
      # menu of the caused stack (and `QMenuBar::hovered` on the bar, which a
      # `MenuBar` does by re-emitting its menus'), so a listener on the root
      # menu or the bar hears a hover at any depth. The leaving highlight (a
      # `nil`) is this menu's alone: above it, the row the submenu hangs off is
      # still the highlighted one.
      private def relay_hovered(act : Action) : Nil
        m = self
        while m
          m.emit ::Crysterm::Event::ActionHovered, act
          m = m.parent_menu || m.@torn_tip_root
        end
      end

      # Re-sends the highlighted action's status tip: a closed submenu
      # cleared the bar (its own highlight left), and the parent's row is
      # the highlight again.
      protected def reannounce_tip : Nil
        return unless visible?
        act = @tip_action || return
        tip_root.emit ::Crysterm::Event::StatusTip, (act.status_tip || "")
      end

      # The menu whose listeners hear this chain's status tips: the chain's
      # root — or, under a torn-off menu, the root of the chain it was torn off
      # while that lives (`menu/tear_off.cr`), so a torn-off palette's tips
      # still reach the `MenuBar` and the status bar as Qt's reach the main
      # window through the `QTornOffMenu`'s caused stack. Followed as far as
      # it goes: a copy torn off a torn-off menu's submenu reports through the
      # first copy to the bar's menu.
      private def tip_root : Menu
        root = root_menu
        while up = root.@torn_tip_root
          root = up
        end
        root
      end

      # Starts the wake-up for *act*'s tooltip, when tooltips are on and the
      # action has one that says more than its label (Qt's `QAction#toolTip`
      # falls back to the text, and a tooltip repeating the row is noise —
      # the label as the row shows it, its `&` marker resolved). The timer's
      # block checks that *act* is still the one highlighted and tooltips
      # still on: a highlight that moved meanwhile stopped the timer, but the
      # tick may already be in flight.
      private def arm_tool_tip(act : Action) : Nil
        return unless tool_tips_visible?
        text = act.tool_tip
        return if text.nil? || text.empty? || text == ::Crysterm::Mnemonic.parse(act.text)[0]
        win = window? || return
        @tip_timer = win.after(Config.tool_tip_delay) do
          @tip_timer = nil
          # Tooltips turned off meanwhile — the `menu.tool_tips` option, which
          # no setter of this menu's sees — leave the wake-up without a tip.
          show_tip_popup text if @tip_action.same?(act) && visible? && tool_tips_visible?
        end
      end

      # Puts *text* up in the popup beside the highlighted row: sized to the
      # text by `ToolTip#show_at`, then placed as `#open_submenu` places a
      # submenu — against the row, right of the menu or left of it when the
      # right does not fit, clamped on-window (`Overlay.place_child`).
      # Nothing before the first render: there is no row to sit beside yet.
      private def show_tip_popup(text : String) : Nil
        win = window? || return
        lp = lpos || return
        tip = (@tip_popup = refresh_satellite(@tip_popup)) || begin
          t = ToolTip.new window: win
          win.append t
          @tip_popup = t
        end
        row_top = lp.yi + itop + (current_index - @child_base)
        tip.show_at lp.xl, row_top, text
        size = {tip.width_spec.as?(Int) || 1, tip.height_spec.as?(Int) || 1}
        Overlay.place_child(tip, {lp.xi, row_top, lp.xl - lp.xi, 1}, size,
          [Overlay::Side::Right, Overlay::Side::Left])
        win.update
      end

      # Takes the popup down, whatever it shows, and forgets a pending
      # wake-up.
      protected def hide_tip_popup : Nil
        @tip_timer.try &.stop
        @tip_timer = nil
        @whats_this_shown = false
        if (tip = @tip_popup) && tip.visible?
          tip.hide
          tip.window?.try &.update
        end
      end

      # `F1` on a highlighted action with a What's This text shows it in the
      # popup (returns whether it consumed *e*); any other key takes a shown
      # What's This down and is handled as usual. `F1` on an action without
      # one is not consumed, as in Qt.
      private def whats_this_pressed(e) : Bool
        hide_tip_popup if @whats_this_shown
        return false unless e.key == ::Tput::Key::F1 && @show_highlight
        text = selected_action.try &.whats_this
        return false if text.nil? || text.empty?
        hide_tip_popup # a tooltip's pending wake-up would replace the help
        show_tip_popup text
        @whats_this_shown = true
        e.accept
        true
      end

      # Listens for the menu's own hiding, which takes the highlight with it,
      # and for the focus leaving it, which the chain's root — a torn-off menu,
      # whose chain stays up without the focus — answers by dropping its
      # highlight when the focus left the chain (`menu/tear_off.cr`). From
      # `#initialize`.
      private def wire_tips : Nil
        on(::Crysterm::Event::Hide) { highlight_left }
        on(::Crysterm::Event::FocusOut) { |e| root_menu.chain_focus_left e.next_focused }
      end

      # Ends the tips with the menu (from `#destroy`): the popup is destroyed,
      # the wake-up forgotten, a tip of this menu's cleared — and the parent
      # menu's row, the highlight again once its submenu is gone, says its
      # own tip anew.
      protected def drop_tips : Nil
        highlight_left
        Widget.destroy_satellite @tip_popup
        @tip_popup = nil
        parent_menu.try &.reannounce_tip
      end
    end
  end
end
