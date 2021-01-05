require "./node"
require "./element"

module Crysterm
  module Widget
    # Box element
    class Loading < Box
      @type = :loading

      @icons = { '|', '/', '-', '\\' }
      @icon = '|'

      @spinner : Fiber?
      @interval : Time::Span

      @should_exit = false

      def initialize(@interval = 0.2.seconds, **box)
        super **box

        @text = box["content"]? || ""

        # Should be done in super?
        #@text = box["content"]? || ""
        #set_content @text
      end

      def start
        show
        @should_exit = false

        @spinner = Fiber.new {
          pos = 0
          loop do
            break if @should_exit
            @icon = @icons[pos]
            pos = (pos + 1) % @icons.size
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

      def render
        clear_pos true
        set_content "#{@icon} #{@text}", true
        super
      end
    end
  end
end
