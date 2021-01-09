require "./node"
require "./element"

module Crysterm
  # Box element
  class Loading < Box
    @spinner : Fiber?
    @interval : Time::Span

    @should_exit = true

    getter icons : Array(String)
    getter icon : Text

    def initialize(
      @interval = 0.2.seconds,
      **box
    )
      super **box

      @icons = ["|", "/", "-", "\\"]

      @pos = 0

      @icon = Text.new \
        align: "center",
        top: 2,
        left: 1,
        right: 1,
        height: 1,
        content: @icons[0]

      append @icon
    end

    def start(text = nil)
      # return if @should_exit
      @should_exit = false

      show
      set_content text || @content

      @screen.lock_keys = true

      @spinner = Fiber.new {
        loop do
          break if @should_exit
          @icon.set_content icons[@pos]
          @pos = (@pos + 1) % icons.size
          @screen.render
          sleep @interval
        end
      }.enqueue
    end

    def stop
      @screen.lock_keys = false
      hide
      @should_exit = true
      render
    end

    def toggle
      @should_exit ? start : stop
    end
  end
end
