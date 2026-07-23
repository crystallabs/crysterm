require "./box"
require "../action"
require "../mixin/action_bar"
require "../mixin/action_watcher"

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
      include Mixin::ActionWatcher

      # The action backing each button box (absent for plain buttons/separators).
      @item_actions = {} of Widget::Box => Action

      def initialize(**listbar)
        super(**listbar.merge(keys: true))
        setup_action_bar mouse: true, auto_prefix: false
        # Buttons pack flush — no gap cells between them (only trailing the last
        # one); each button box keeps its own side padding.
        @item_gap = 0
        # Install/withdraw keyboard accelerators with the bar's attach lifecycle,
        # so e.g. `Ctrl+B` fires whenever the bar is on a window, not only on click.
        on(::Crysterm::Event::Attached) { install_action_shortcuts }
        # Uninstall from the window carried on the event: `parent`/`window` are
        # nulled before `Event::Detached` is emitted, so `window?` is already nil
        # here — the previous window comes via the payload.
        on(::Crysterm::Event::Detached) { |e| uninstall_action_shortcuts e.object.as?(::Crysterm::Window) }
      end

      # Adds a button for *action*, returns its box. Clicking triggers the action
      # (toggling first when checkable); the action's tooltip is carried over.
      def add_action(action : Action) : Widget::Box
        item = add_item(action.display_label) { activate_action action }
        @item_actions[item] = action
        # Associate this bar with the action and reflect external state changes
        # (Qt's `QAction::changed()`): toggling a checkable action's `checked`
        # from elsewhere must re-light its button.
        watch_action(action) do |_e|
          refresh
          request_render
          nil
        end
        action.tool_tip.try { |t| item.tool_tip = t }
        # Wire the accelerator now if already on a window; otherwise
        # `install_action_shortcuts` does it on attach.
        window?.try { |w| action.install_shortcut w, self }
        refresh
        item
      end

      # Adds a plain button running *block* when clicked.
      def add_button(text : String, &block : ->) : Widget::Box
        add_item(text) { block.call }
      end

      # Operator alias for `#add_action`, e.g. `toolbar << action`. `Action` is
      # not a `Widget`, so this doesn't collide with `Mixin::Children#<<(Widget)`
      # (which still appends a raw child). `#add_action` stays the primary,
      # Qt-faithful spelling (and returns the button box); `#<<` returns `self`.
      def <<(action : Action) : self
        add_action action
        self
      end

      private def activate_action(action : Action) : Nil
        # `#activate` toggles a checkable action and fires it (Qt semantics,
        # except re-selecting an exclusive `ActionGroup`'s checked member, which
        # stays checked); the bar must not pre-toggle or it would cancel out.
        action.activate
        refresh
      end

      # Installs every backing action's keyboard accelerator on the bar's window.
      private def install_action_shortcuts : Nil
        w = window? || return
        @item_actions.each_value(&.install_shortcut(w, self))
      end

      # Withdraws every backing action's accelerator from *w* (the window the bar
      # is leaving, supplied via the `Detached` event payload).
      private def uninstall_action_shortcuts(w : ::Crysterm::Window?) : Nil
        return unless w
        @item_actions.each_value(&.uninstall_shortcut(w))
      end

      # A tool bar has no persistent cursor: only checkable buttons stay lit, so
      # the highlight tracks each action's checked state rather than the raw
      # selection.
      protected def highlight_item?(item : Widget, index : Int32, offset : Int32) : Bool
        act = @item_actions[item]?
        !!(act && act.checkable? && act.checked?)
      end

      # Re-light after a checkable toggles outside a selection (external
      # `Action#changed`, `#activate_action`, add-time state).
      private def refresh : Nil
        reapply_highlight
      end

      # Remove every per-action `Changed` handler and association before teardown,
      # so no stale handler fires against the destroyed bar and no dead bar lingers
      # in `action.associated_widgets`.
      def destroy
        # Withdraw the accelerators NOW, while `@item_actions` is still
        # populated: the `Detached` emitted during `super`'s teardown would run the
        # uninstall handler over an already-cleared collection, leaving every
        # action's shortcut registered on the window forever.
        uninstall_action_shortcuts window?
        unwatch_all_actions
        @item_actions.clear
        super
      end
    end
  end
end
