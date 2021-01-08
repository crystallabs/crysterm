require "./node"
require "./element"

module Crysterm
  module Widget
    # Box element
    class Loading < Box
      @type = :loading

      @spinner : Fiber?
      @interval : Time::Span

      @should_exit = false

      getter! icons : Tuple(Text,Text,Text,Text)
      getter! icon : Text

      def initialize(
        @interval = 0.2.seconds,
        **box
      )

        super **box

        #@text = box["content"]? || ""

        @icons = {
          Text.new(parent: self, align: "center",
            top: 2, left: 1, right: 1, height: 1, content: "|"),
          Text.new(parent: self, align: "center",
            top: 2, left: 1, right: 1, height: 1, content: "/"),
          Text.new(parent: self, align: "center",
            top: 2, left: 1, right: 1, height: 1, content: "-"),
          Text.new(parent: self, align: "center",
            top: 2, left: 1, right: 1, height: 1, content: "\\")
        }
        @icon = icons[0]

        # Should be done in super?
        #@text = box["content"]? || ""
        #set_content @text
      end

      def start(text)
        return if @should_exit
        @should_exit = false

        show
        set_content text

        @spinner = Fiber.new {
          pos = 0
          loop do
            break if @should_exit
            @icon = icons[pos]
            pos = (pos + 1) % icons.size
            @screen.render
            sleep @interval
          end
        }.enqueue
      end

      def stop
        @screen.lock_keys = false
        @should_exit = true
        hide
        render
      end

      def toggle
        @should_exit ? start : stop
      end
    end
  end
end
