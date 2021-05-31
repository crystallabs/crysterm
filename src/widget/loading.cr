module Crysterm
  class Widget
    # Box element
    class Loading < Box
      @spinner : Fiber?

      @interval : Time::Span

      property? compact = false

      protected property should_exit = true

      @orig_text = ""
      @text : String?

      # XXX Use a better name than 'icons', so that it doesn't
      # seem to imply longer text can't be used.

      getter icons : Array(String)
      getter icon : Text

      def initialize(
        @compact = false,
        @interval = 0.2.seconds,
        @icons = ["|", "/", "-", "\\"],
        @step = 1,
        **box
      )
        box["content"]?.try do |c|
          @orig_text = c
        end

        super **box

        @pos = 0 # @step > 0 ? (@step - 1) : @step

        @icon = Text.new \
          align: Tput::AlignFlag::Center,
          top: 2,
          left: 1,
          right: 1,
          height: 1,
          content: @icons[0]

        append @icon
      end

      def start(@text = nil)
        # return if @should_exit
        @should_exit = false

        # XXX Keep on top:
        # @parent.try do |p|
        #   detach
        #   p.append self
        # end

        show
        set_content @text || @orig_text

        @screen.lock_keys = true

        @spinner = Fiber.new {
          loop do
            break if @should_exit
            @icon.set_content icons[@pos]
            @pos = (@pos + @step) % icons.size
            @screen.render
            sleep @interval
          end
        }.enqueue
      end

      def stop
        @screen.lock_keys = false
        hide
        @should_exit = true
        @text = nil
        @screen.render
      end

      def toggle
        @should_exit ? start : stop
      end

      def render
        clear_pos true
        if compact?
          set_content "#{@icon.content} #{@text || @orig_text}", true
          super false
        else
          set_content @text || @orig_text
          super
        end
      end
    end
  end
end
