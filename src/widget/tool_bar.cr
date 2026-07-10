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

      # Per-action `Event::Changed` handler, kept so it can be removed in
      # `#destroy` (mirroring `Menu`'s `@action_changed`); otherwise destroying
      # the bar leaves a stale handler running `refresh`/`request_render` on a
      # destroyed widget for every future change of that action.
      @action_changed = {} of Action => ::Proc(::Crysterm::Event::Changed, ::Nil)

      def initialize(**listbar)
        super(**listbar.merge(keys: true))
        setup_action_bar mouse: true, auto_prefix: false
        # Buttons pack flush — no gap cells between them (only trailing the last
        # one); each button box keeps its own side padding. Same as MenuBar.
        @item_gap = 0
        # Install/withdraw keyboard accelerators with the bar's attach lifecycle,
        # so e.g. `Ctrl+B` fires whenever the bar is on a window, not only on click.
        on(::Crysterm::Event::Attach) { install_action_shortcuts }
        # Uninstall from the window carried on the event: `Widget#remove` nulls
        # `parent`/`window` before `Window#detach` emits `Event::Detach`, so
        # `window?` is already nil here — the previous window comes via the payload.
        on(::Crysterm::Event::Detach) { |e| uninstall_action_shortcuts e.object.as?(::Crysterm::Window) }
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
        handler = ->(_e : ::Crysterm::Event::Changed) do
          refresh
          request_render
          nil
        end
        action.on ::Crysterm::Event::Changed, handler
        @action_changed[action] = handler
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

      # Withdraws every backing action's accelerator from *w* (the window the bar
      # is leaving, supplied via the `Detach` event payload).
      private def uninstall_action_shortcuts(w : ::Crysterm::Window?) : Nil
        return unless w
        @item_actions.each_value(&.uninstall_shortcut(w))
      end

      # A tool bar has no persistent cursor: only checkable buttons stay lit, so
      # the highlight tracks each action's checked state rather than the raw
      # selection. `Mixin::ActionBar#selekt` re-applies this via the shared
      # `#reapply_highlight` scaffold, so a click/move no longer leaves the last
      # button highlighted.
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
      # in `action.associated_widgets`. (Keyboard accelerators are withdrawn on the
      # `Detach` emitted during teardown.)
      def destroy
        # Withdraw the accelerators NOW, while `@item_actions` is still
        # populated: the `Detach` emitted during `super`'s teardown runs the
        # uninstall handler over an already-cleared collection, leaving every
        # action's shortcut registered on the window forever.
        uninstall_action_shortcuts window?
        @item_actions.each_value do |action|
          if h = @action_changed.delete action
            action.off ::Crysterm::Event::Changed, h
          end
          action.dissociate self
        end
        @action_changed.clear
        @item_actions.clear
        super
      end
    end
  end
end
