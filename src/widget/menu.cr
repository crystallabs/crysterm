require "../action"

module Crysterm
  class Widget
    # A vertical menu of `Action`s, built on `List`.
    #
    # The (visible) actions are shown as selectable rows; arrow keys (and, with
    # `vi: true`, `j`/`k`) navigate, and Enter — or a click on the highlighted
    # row — activates the selected action. Activating emits the action's
    # `Event::Triggered`, received by any listener attached via
    # `action.on(Crysterm::Event::Triggered) { ... }`. Disabled actions are
    # listed but not activated.
    #
    # ```
    # menu = Widget::Menu.new parent: screen
    # quit = Action.new "Quit"
    # quit.on(Crysterm::Event::Triggered) { exit }
    # menu << quit
    # menu.focus
    # ```
    class Menu < List
      # Optional title, shown as the widget's label.
      property title : String = ""

      # The actions in this menu, in display order.
      property actions = [] of Action

      def initialize(title = "", keys = nil, **widget)
        # `keys` is absorbed: `List` always enables key handling.
        @title = title

        super **widget

        set_label @title unless @title.empty?
        sync_items

        # Enter (or a click on the already-selected row) emits `ActionItem`;
        # activate the corresponding action.
        on(::Crysterm::Event::ActionItem) { |e| activate_index e.index }
      end

      # Adds *action* to the menu (no-op if already present).
      def <<(action : Action)
        unless @actions.includes? action
          @actions << action
          sync_items
        end
        self
      end

      # Removes *action* from the menu.
      def >>(action : Action)
        if @actions.delete action
          sync_items
        end
        self
      end

      # The currently highlighted action, or `nil` when the menu is empty.
      def selected_action : Action?
        visible_actions[selected]?
      end

      # Activates the highlighted action (as if Enter were pressed on it).
      def activate_selected
        activate_index selected
      end

      private def visible_actions : Array(Action)
        @actions.select &.visible?
      end

      # Rebuilds the list rows from the visible actions' text.
      private def sync_items
        set_items visible_actions.map(&.text)
      end

      private def activate_index(index : Int32)
        action = visible_actions[index]?
        return unless action
        return unless action.enabled
        action.activate
      end
    end
  end
end
