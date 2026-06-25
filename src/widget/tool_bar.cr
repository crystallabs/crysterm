require "./listbar"
require "../action"

module Crysterm
  class Widget
    # Horizontal bar of action buttons, modeled after Qt's `QToolBar`.
    #
    # Holds `Action` buttons (added with `#add_action`), plain command buttons
    # (`#add_button`), and separators (`#add_separator`). Clicking a button
    # triggers it; a checkable action's button stays highlighted while checked.
    # Each action's `#tool_tip` becomes the button's hover tooltip.
    #
    # Built on `ListBar` (horizontal layout, keyboard navigation, hotkeys) with
    # plain labels (no `1:` prefixes).
    #
    # ```
    # tb = Widget::ToolBar.new parent: screen, top: 0, left: 0, width: "100%", height: 1
    # tb.add_button("New") { new_doc }
    # tb.add_separator
    # bold = Action.new "Bold"; bold.checkable = true
    # tb.add_action bold
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![ToolBar screenshot](../../examples/widget/tool_bar/tool_bar-capture5s.apng)
    # <!-- /widget-examples:capture -->
    class ToolBar < ListBar
      # The action backing each button box (absent for plain buttons/separators).
      @item_actions = {} of Widget::Box => Action

      def initialize(**listbar)
        super(**listbar.merge(mouse: true, keys: true))
        @auto_prefix = false
      end

      # Adds a button for *action*, returns its box. Clicking triggers the action
      # (toggling first when checkable); the action's tooltip is carried over.
      def add_action(action : Action) : Widget::Box
        item = add(action.text) { activate_action action }
        @item_actions[item] = action
        action.tool_tip.try { |t| item.tool_tip = t }
        # Reflect external state changes (Qt's `QAction::changed()`): toggling a
        # checkable action's `checked` from elsewhere must re-light its button.
        action.on(::Crysterm::Event::Changed) do
          refresh
          request_render
        end
        refresh
        item
      end

      # Adds a plain button running *block* when clicked.
      def add_button(text : String, &block : ->) : Widget::Box
        add(text) { block.call }
      end

      private def activate_action(action : Action) : Nil
        action.checked = !action.checked? if action.checkable?
        action.activate
        refresh
      end

      # A tool bar has no persistent cursor: only checkable buttons stay lit (when
      # checked). Re-applied after every `ListBar#selekt` (which a click/move would
      # otherwise leave highlighting the last button).
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
