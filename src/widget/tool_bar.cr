require "./box"
require "../action"
require "../mixin/action_bar"
require "../mixin/action_watcher"

module Crysterm
  class Widget
    # Horizontal bar of action buttons, modeled after Qt's `QToolBar`.
    #
    # Holds `Action` buttons (added with `#add_action`), plain command buttons
    # (`#add_button`), separators (`#add_separator`), and arbitrary embedded
    # widgets (`#add_widget`), all flowing in one strip. Clicking a button
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
        wire_action_shortcuts
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

      # Creates an `Action` labeled *text*, appends it, and returns its button
      # box — also connecting *block* to the action's `Event::Triggered` (Qt's
      # `QToolBar#addAction(text, receiver, slot)`; the text-based counterpart
      # to the `Action`-based overload above).
      def add_action(text : String, &block : ->) : Widget::Box
        action = Action.new text
        action.on(::Crysterm::Event::Triggered) { block.call }
        add_action action
      end

      # Appends every action in *actions*, in order (Qt's
      # `QToolBar#addActions`).
      def add_actions(actions : Enumerable(Action)) : self
        actions.each { |a| add_action a }
        self
      end

      # Embeds an arbitrary *widget* in the action strip and returns it (Qt's
      # `QToolBar#addWidget`, which likewise hands back a handle — there, the
      # generated `QWidgetAction` — for later removal; here the widget itself is
      # the handle, accepted by both `#remove_widget` and `#remove_item`).
      #
      # The widget becomes a strip item like any button: appended after the items
      # already on the bar, re-packed with them whenever the row changes, and
      # reparented into a host item box that reserves *width* cells for it —
      # defaulting to the widget's own fixed `#width`, or, for a stretched one,
      # to whatever it currently resolves to. Its `top`/`left` are pinned to the
      # host's origin; its size, style, and focus/key handling stay its own. A
      # widget taller than the bar is clipped by it, like any oversized child.
      #
      # Embedded items are deliberately NOT part of the bar's item cycling:
      # Left/Right, the number keys and Enter step over them just as they do over
      # separators, and no click-to-trigger handler is installed above them. The
      # bar has no command to run for them, and hijacking the arrow keys would
      # fight whatever the widget does with them; reach an embedded widget the
      # way it is normally reached — by clicking it, or through the window's Tab
      # focus chain.
      #
      # ```
      # tb.add_button("Find") { search }
      # tb.add_widget Widget::LineEdit.new(width: 20, height: 1)
      # ```
      def add_widget(widget : Widget, width : Int32? = nil) : Widget
        add_embedded_item widget, width
        widget
      end

      # Removes a widget embedded with `#add_widget`, returning it, or `nil` when
      # it is not on this bar. The widget is detached free-standing (not
      # destroyed) — it can be re-added here or parented elsewhere — and the
      # remaining items re-pack on the next render.
      def remove_widget(widget : Widget) : Widget?
        remove_item(widget) && widget
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

      # The bar owns its buttons' backing actions, on top of any installed with
      # `Widget#add_action`.
      private def each_shortcut_action(&block : Action ->) : Nil
        super(&block)
        @item_actions.each_value(&block)
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
