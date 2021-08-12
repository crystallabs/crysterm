require "../action"

module Crysterm
  class Widget
    class Menu < Widget
      property title : String = ""

      property actions = [] of Action

      def initialize(**widget)
        super **widget
      end

      def initialize(@title, **widget)
        super **widget
      end

      def <<(action : Action)
        @actions << action unless @actions.includes? action
      end

      def >>(action : Action)
        @actions.delete action
      end
    end
  end
end
