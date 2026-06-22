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

      # Appends a non-selectable separator rule (Qt's `QMenu#addSeparator`).
      def add_separator
        @actions << Action.separator
        sync_items
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

      # Rebuilds the list rows from the visible actions, drawing a `[x]`/`[ ]`
      # marker for checkable actions and a right-aligned shortcut column, and
      # rendering separators as a horizontal rule.
      private def sync_items
        acts = visible_actions
        any_checkable = acts.any? &.checkable?

        lefts = acts.map do |a|
          next "" if a.separator?
          prefix = if a.checkable?
                     a.checked? ? "[x] " : "[ ] "
                   elsif any_checkable
                     "    "
                   else
                     ""
                   end
          "#{prefix}#{a.text}"
        end
        rights = acts.map { |a| a.separator? ? "" : (a.shortcut.try(&.to_s) || "") }

        maxleft = lefts.max_of?(&.size) || 0
        maxright = rights.max_of?(&.size) || 0
        total = maxleft + (maxright > 0 ? 2 + maxright : 0)

        rows = acts.map_with_index do |a, i|
          if a.separator?
            "─" * Math.max(1, total)
          else
            row = lefts[i].ljust(maxleft)
            row += "  " + rights[i].rjust(maxright) if maxright > 0
            row
          end
        end

        set_items rows
      end

      # Skips over separator rows so the highlight never rests on one. The
      # direction is inferred from whether the requested index is above or below
      # the current selection.
      def selekt(index : Int)
        acts = visible_actions
        unless acts.empty?
          dir = index >= selected ? 1 : -1
          index = skip_separators index, dir, acts
        end
        super index
      end

      private def skip_separators(index : Int, dir : Int, acts : Array(Action)) : Int32
        n = acts.size
        return index.to_i if n == 0
        i = index.clamp(0, n - 1)
        n.times do
          a = acts[i]?
          break unless a && a.separator?
          ni = i + dir
          break if ni < 0 || ni >= n
          i = ni
        end
        i
      end

      private def activate_index(index : Int32)
        action = visible_actions[index]?
        return unless action
        return if action.separator?
        return unless action.enabled

        # Toggle a checkable action's state and redraw its marker before firing.
        if action.checkable?
          action.checked = !action.checked?
          sel = selected
          sync_items
          selekt sel
        end

        action.activate
      end
    end
  end
end
