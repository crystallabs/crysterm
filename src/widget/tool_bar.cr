require "./box"
require "../action"
require "../mixin/action_bar"

module Crysterm
  class Widget
    # Horizontal bar of action buttons, modeled after Qt's `QToolBar`.
    #
    # Holds `Action` buttons (added with `#add_action`), plain command buttons
    # (`#add_button`), and separators (`#add_separator`). Clicking a button
    # triggers it; a checkable action's button stays highlighted while checked.
    # Each action's `#tool_tip` becomes the button's hover tooltip.
    #
    # Built on `Mixin::ActionBar` (horizontal layout, keyboard navigation,
    # hotkeys) with plain labels (no `1:` prefixes).
    #
    # ```
    # tb = Widget::ToolBar.new parent: window, top: 0, left: 0, width: "100%", height: 1
    # tb.add_button("New") { new_doc }
    # tb.add_separator
    # bold = Action.new "Bold"; bold.checkable = true
    # tb.add_action bold
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![ToolBar screenshot](../../tests/widget/tool_bar/tool_bar.5s.apng)
    # <!-- /widget-examples:capture -->
    class ToolBar < Box
      include Mixin::ActionBar

      # The action backing each button box (absent for plain buttons/separators).
      @item_actions = {} of Widget::Box => Action

      def initialize(**listbar)
        super(**listbar.merge(keys: true))
        setup_action_bar mouse: true, auto_prefix: false
        # Buttons pack flush — no gap cells between them (only trailing the last
        # one); each button box keeps its own side padding. Same as MenuBar.
        @item_gap = 0
        # Install/withdraw keyboard accelerators with the bar's attach lifecycle,
        # so e.g. `Ctrl+B` fires whenever the bar is on a window, not only on click.
        on(::Crysterm::Event::Attach) { install_action_shortcuts }
        on(::Crysterm::Event::Detach) { uninstall_action_shortcuts }
      end

      # Adds a button for *action*, returns its box. Clicking triggers the action
      # (toggling first when checkable); the action's tooltip is carried over.
      def add_action(action : Action) : Widget::Box
        item = add(action.display_label) { activate_action action }
        @item_actions[item] = action
        action.associate self # Qt's QAction::associatedWidgets bookkeeping
        action.tool_tip.try { |t| item.tool_tip = t }
        # Reflect external state changes (Qt's `QAction::changed()`): toggling a
        # checkable action's `checked` from elsewhere must re-light its button.
        action.on(::Crysterm::Event::Changed) do
          refresh
          request_render
        end
        # Wire the accelerator now if already on a window; otherwise
        # `install_action_shortcuts` does it on attach.
        window?.try { |w| action.install_shortcut w, self }
        refresh
        item
      end

      # Adds a plain button running *block* when clicked.
      def add_button(text : String, &block : ->) : Widget::Box
        add(text) { block.call }
      end

      private def activate_action(action : Action) : Nil
        # `#activate` toggles a checkable action and fires it (Qt semantics); the
        # bar must not pre-toggle or it would cancel out.
        action.activate
        refresh
      end

      # Installs every backing action's keyboard accelerator on the bar's window.
      private def install_action_shortcuts : Nil
        w = window? || return
        @item_actions.each_value(&.install_shortcut(w, self))
      end

      # Withdraws every backing action's accelerator from the bar's window.
      private def uninstall_action_shortcuts : Nil
        w = window? || return
        @item_actions.each_value(&.uninstall_shortcut(w))
      end

      # A tool bar has no persistent cursor: only checkable buttons stay lit.
      # Re-applied after every `Mixin::ActionBar#selekt`, which a click/move
      # would otherwise leave highlighting the last button.
      private def refresh : Nil
        items.each do |it|
          act = @item_actions[it]?
          it.state = (act && act.checkable? && act.checked?) ? :selected : :normal
        end
      end

      def selekt(offset : Int)
        super
        refresh
      end
    end
  end
end
